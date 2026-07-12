#lang racket/base

(require ffi/unsafe
         racket/runtime-path
         (only-in "private/logits.rkt"
                  function->logits-view)
         (only-in "private/model.rkt"
                  tokenizer
                  provider
                  model))

(provide llama-cpp-model)

(define-runtime-path default-native-lib "native/llama/build/librackllm_llama.so")

(struct native-api
  (model-open model-close vocab-size eog-count eog-ref tokenize detokenize token->piece
              session-start session-reset session-close session-logits session-commit)
  #:transparent)

(define sessions (make-hash))
(define next-session-id (box 0))

(define api-cache (make-hash))

(define (llama-cpp-model #:model-path model-path
                         #:native-lib [native-lib-path (getenv "RACK_LLM_LLAMA_NATIVE_LIB")]
                         #:context-size [context-size 512]
                         #:threads [threads 1]
                         #:gpu-layers [gpu-layers -1])
  (define api (load-native-api native-lib-path))
  (define path-string
    (path->string (if (path? model-path)
                      model-path
                      (string->path model-path))))
  (define handle
    (call/native-error
     'llama-cpp-model
     (lambda (err err-len)
       ((native-api-model-open api) path-string context-size threads gpu-layers err err-len))))
  (define size ((native-api-vocab-size api) handle))
  (define eog-token-ids
    (for/list ([i (in-range ((native-api-eog-count api) handle))])
      ((native-api-eog-ref api) handle i)))
  (define idle-sessions (box '()))
  (define tok
    (tokenizer
     #:vocab-size size
     #:token-ref
     (lambda (id)
       (native-token->piece api handle id))
     #:tokenize
     (lambda (text)
       (native-tokenize api handle text))
     #:detokenize
     (lambda (ids)
       (native-detokenize api handle ids))))
  (define llm-provider
    (provider
     #:vocab-size size
     #:eog-token-ids eog-token-ids
     #:start-session
     (lambda (prompt-ids)
       (define idle (unbox idle-sessions))
       (if (null? idle)
           (native-session-start api handle prompt-ids)
           (let ([ptr (car idle)])
             (set-box! idle-sessions (cdr idle))
             (with-handlers ([exn:fail?
                              (lambda (exn)
                                (set-box! idle-sessions
                                          (cons ptr (unbox idle-sessions)))
                                (raise exn))])
               (native-session-reset! api ptr prompt-ids))
             (register-session! ptr))))
     #:next-logits/session
     (lambda (session)
       (native-session-logits-view api (session-ptr session) size))
     #:commit-token!
     (lambda (session token-id)
       (call/native-error
        'llama-cpp-commit-token!
        (lambda (err err-len)
          (zero? ((native-api-session-commit api)
                  (session-ptr session)
                  token-id
                  err
                  err-len))))
       (void))
     #:end-session!
     (lambda (session)
       (set-box! idle-sessions
                 (cons (unregister-session! session) (unbox idle-sessions))))))
  (model tok
         llm-provider
         (hash 'name 'llama-cpp 'model-path path-string)
         (lambda ()
           (for ([ptr (in-list (unbox idle-sessions))])
             ((native-api-session-close api) ptr))
           (set-box! idle-sessions '())
           ((native-api-model-close api) handle))))

(define (load-native-api override)
  (define key (or override 'default))
  (hash-ref api-cache
            key
            (lambda ()
              (define api (open-native-api override))
              (hash-set! api-cache key api)
              api)))

(define (open-native-api override)
  (define lib (open-native-lib override))
  (define (ffi name type)
    (get-ffi-obj name lib type))
  (native-api
   (ffi "rackllm_llama_model_open" (_fun _string _int32 _int32 _int32 _bytes _int64 -> _pointer))
   (ffi "rackllm_llama_model_close" (_fun _pointer -> _void))
   (ffi "rackllm_llama_vocab_size" (_fun _pointer -> _int32))
   (ffi "rackllm_llama_eog_count" (_fun _pointer -> _int32))
   (ffi "rackllm_llama_eog_ref" (_fun _pointer _int32 -> _int32))
   (ffi "rackllm_llama_tokenize" (_fun _pointer _bytes _int32 _pointer _int32 -> _int32))
   (ffi "rackllm_llama_detokenize" (_fun _pointer _pointer _int32 _bytes _int32 -> _int32))
   (ffi "rackllm_llama_token_to_piece" (_fun _pointer _int32 _bytes _int32 -> _int32))
   (ffi "rackllm_llama_session_start" (_fun _pointer _pointer _int32 _bytes _int64 -> _pointer))
   (ffi "rackllm_llama_session_reset" (_fun _pointer _pointer _int32 _bytes _int64 -> _int32))
   (ffi "rackllm_llama_session_close" (_fun _pointer -> _void))
   (ffi "rackllm_llama_session_logits" (_fun _pointer _bytes _int64 -> _pointer))
   (ffi "rackllm_llama_session_commit" (_fun _pointer _int32 _bytes _int64 -> _int32))))

(define (open-native-lib override)
  (define candidates
    (if override
        (list override)
        (list (path->string default-native-lib)
              "rackllm_llama"
              "librackllm_llama")))
  (let loop ([remaining candidates]
             [errors '()])
    (cond
      [(null? remaining)
       (error 'llama-cpp-model
              "cannot load native llama.cpp shim; run `make native-llama` or set RACK_LLM_LLAMA_NATIVE_LIB; tried ~a; errors: ~a"
              candidates
              (reverse errors))]
      [else
       (define candidate (car remaining))
       (with-handlers ([exn:fail?
                        (lambda (exn)
                          (loop (cdr remaining)
                                (cons (format "~a: ~a" candidate (exn-message exn))
                                      errors)))])
         (ffi-lib candidate))])))

(define (native-lib-description override)
  (or override (path->string default-native-lib)))

(define (make-int32-buffer ids)
  (define ptr (malloc _int32 (max 1 (length ids))))
  (for ([id (in-list ids)]
        [i (in-naturals)])
    (ptr-set! ptr _int32 i id))
  ptr)

(define (native-tokenize api handle text)
  (define bytes (string->bytes/utf-8 text))
  (define needed ((native-api-tokenize api)
                  handle
                  bytes
                  (bytes-length bytes)
                  #f
                  0))
  (when (negative? needed)
    (error 'llama-cpp-tokenize "native tokenizer failed for ~s" text))
  (define out (malloc _int32 (max 1 needed)))
  (define count ((native-api-tokenize api)
                 handle
                 bytes
                 (bytes-length bytes)
                 out
                 needed))
  (unless (= count needed)
    (error 'llama-cpp-tokenize
           "native tokenizer returned ~a tokens after sizing returned ~a"
           count
           needed))
  (for/list ([i (in-range count)])
    (ptr-ref out _int32 i)))

(define (native-detokenize api handle ids)
  (define token-ptr (make-int32-buffer ids))
  (define needed ((native-api-detokenize api) handle token-ptr (length ids) #f 0))
  (when (negative? needed)
    (set! needed (- needed)))
  (define out (make-bytes (max 1 needed)))
  (define count ((native-api-detokenize api)
                 handle
                 token-ptr
                 (length ids)
                 out
                 (bytes-length out)))
  (when (negative? count)
    (error 'llama-cpp-detokenize "native detokenizer failed for token ids: ~s" ids))
  (bytes->string/utf-8 (subbytes out 0 count) #\uFFFD))

(define (native-token->piece api handle id)
  (define needed ((native-api-token->piece api) handle id #f 0))
  (when (negative? needed)
    (set! needed (- needed)))
  (define out (make-bytes (max 1 needed)))
  (define count ((native-api-token->piece api) handle id out (bytes-length out)))
  (when (negative? count)
    (error 'llama-cpp-token-ref "native token->piece failed for token id ~a" id))
  (bytes->string/utf-8 (subbytes out 0 count) #\uFFFD))

(define (native-session-start api handle ids)
  (define ptr
    (call/native-error
     'llama-cpp-start-session
     (lambda (err err-len)
       ((native-api-session-start api)
        handle
        (make-int32-buffer ids)
        (length ids)
        err
        err-len))))
  (register-session! ptr))

(define (register-session! ptr)
  (define id (unbox next-session-id))
  (set-box! next-session-id (add1 id))
  (hash-set! sessions id ptr)
  id)

(define (native-session-reset! api ptr ids)
  (call/native-error
   'llama-cpp-reset-session!
   (lambda (err err-len)
     (zero? ((native-api-session-reset api)
             ptr
             (make-int32-buffer ids)
             (length ids)
             err
             err-len))))
  (void))

(define (session-ptr session)
  (unless (exact-nonnegative-integer? session)
    (error 'llama-cpp-session "expected native session id, got: ~s" session))
  (hash-ref sessions
            session
            (lambda ()
              (error 'llama-cpp-session "unknown or closed native session id: ~a" session))))

(define (unregister-session! session)
  (define ptr (session-ptr session))
  (hash-remove! sessions session)
  ptr)

(define (native-session-logits-view api session vocab-size)
  (define logits-ptr
    (call/native-error
     'llama-cpp-next-logits/session
     (lambda (err err-len)
       ((native-api-session-logits api) session err err-len))))
  (unless logits-ptr
    (error 'llama-cpp-next-logits/session "native session returned null logits pointer"))
  (function->logits-view
   vocab-size
   (lambda (id)
     (ptr-ref logits-ptr _float id))))

(define (call/native-error who thunk)
  (define err-len 4096)
  (define err (make-bytes err-len 0))
  (define value (thunk err err-len))
  (cond
    [(or (not value) (equal? value #f))
     (error who "~a" (cstring-bytes->string err))]
    [else value]))

(define (cstring-bytes->string bytes)
  (define len
    (or (for/first ([i (in-range (bytes-length bytes))]
                    #:when (zero? (bytes-ref bytes i)))
          i)
        (bytes-length bytes)))
  (define text (bytes->string/utf-8 (subbytes bytes 0 len) #\uFFFD))
  (if (string=? text "") "native llama.cpp call failed" text))
