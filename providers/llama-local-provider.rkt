#lang racket/base

(require file/sha1
         json
         net/base64
         racket/path
         racket/port
         "prompt-rendering.rkt"
         "provider-v2.rkt")

(provide make-llama-local-provider
         make-llama-sidecar-provider
         make-llama-sidecar
         (struct-out llama-sidecar)
         (struct-out decoded-logits-response)
         decode-logits-response)

(struct llama-sidecar
  (request close)
  #:transparent)

(struct decoded-logits-response
  (logits
   vocab-size
   elapsed-ms
   prompt-tokens
   prefix-tokens
   cache-hit?
   session)
  #:transparent)

(define (make-llama-local-provider #:model-path model-path
                                   #:seed [seed 0]
                                   #:context-size [context-size 512]
                                   #:threads [threads 1]
                                   #:runtime [runtime 'stdio-sidecar]
                                   #:chat-template [chat-template #f]
                                   #:command [command (getenv "RACK_LLM_LLAMA_SIDECAR")])
  (case runtime
    [(stdio-sidecar)
     (unless command
       (error 'make-llama-local-provider
              "stdio-sidecar runtime requires RACK_LLM_LLAMA_SIDECAR or #:command"))
     (make-llama-sidecar-provider
      #:model-path model-path
      #:seed seed
      #:context-size context-size
      #:threads threads
      #:chat-template chat-template
      #:process (make-llama-sidecar command))]
    [(ffi)
     (error 'make-llama-local-provider
            "ffi runtime is not implemented; use #:runtime 'stdio-sidecar")]
    [else
     (error 'make-llama-local-provider "unsupported runtime: ~a" runtime)]))

(define (make-llama-sidecar-provider #:model-path model-path
                                     #:process process
                                     #:seed [seed 0]
                                     #:context-size [context-size 512]
                                     #:threads [threads 1]
                                     #:chat-template [chat-template #f])
  (define load-response
    (sidecar-request
     process
     (hash 'op "load"
           'model_path (path->string (path-string->path model-path))
           'seed seed
           'context_size context-size
           'threads threads
           'chat_template (or chat-template 'null))))
  (check-ok 'load load-response)
  (define vocab-size (response-natural load-response 'vocab_size))
  (define initial-session
    (response-string/default load-response 'session "default"))
  (define model-id
    (response-string/default load-response 'model_id (model-path->id model-path)))
  (define model-hash
    (or (response-maybe-string load-response 'model_hash)
        (model-path->hash model-path)))
  (provider
   (make-provider-info 'llama-local
                       'exact-full-vocab
                       model-id
                       model-hash
                       vocab-size)
   (provider-state initial-session)
   (lambda (text)
     (decode-tokenize-response
      (sidecar-request process (hash 'op "tokenize" 'text text))))
   (lambda (ids)
     (decode-detokenize-response
      (sidecar-request process (hash 'op "detokenize" 'tokens ids))))
   (lambda (transcript prefix state)
     (define session
       (if (string? (provider-state-opaque state))
           (provider-state-opaque state)
           initial-session))
     (define response
       (sidecar-request
        process
        (hash 'op "next_logits"
              'session session
              'prompt (plain-renderer transcript "")
              'prefix prefix)))
     (define decoded (decode-logits-response response))
     (unless (= (decoded-logits-response-vocab-size decoded) vocab-size)
       (error 'llama-local
              "sidecar returned vocab_size ~a, expected ~a"
              (decoded-logits-response-vocab-size decoded)
              vocab-size))
     (logits-result
      (decoded-logits-response-logits decoded)
      (provider-state (or (decoded-logits-response-session decoded) session))
      (provider-trace
       (decoded-logits-response-prompt-tokens decoded)
       (decoded-logits-response-prefix-tokens decoded)
       (decoded-logits-response-cache-hit? decoded)
       (decoded-logits-response-elapsed-ms decoded)
       #f)))))

(define (make-llama-sidecar command)
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f "/bin/sh" "-c" command))
  (define lock (make-semaphore 1))
  (llama-sidecar
   (lambda (payload)
     (call-with-semaphore
      lock
      (lambda ()
        (write-json payload stdin)
        (newline stdin)
        (flush-output stdin)
        (define line (read-line stdout 'any))
        (cond
          [(eof-object? line)
           (define err (port->string stderr))
           (error 'llama-sidecar "sidecar closed stdout: ~a" err)]
          [else (string->jsexpr line)]))))
   (lambda ()
     (with-handlers ([exn:fail? void])
       (write-json (hash 'op "close") stdin)
       (newline stdin)
       (flush-output stdin))
     (close-output-port stdin)
     (subprocess-wait proc))))

(define (sidecar-request sidecar payload)
  ((llama-sidecar-request sidecar) payload))

(define (decode-logits-response response)
  (check-ok 'next_logits response)
  (define vocab-size (response-natural response 'vocab_size))
  (define logits
    (cond
      [(hash-has-key? response 'logits)
       (decode-logits-list (hash-ref response 'logits))]
      [(hash-has-key? response "logits")
       (decode-logits-list (hash-ref response "logits"))]
      [else
       (decode-logits-b64
        (response-string response 'logits_b64))]))
  (unless (= (vector-length logits) vocab-size)
    (error 'decode-logits-response
           "logits length ~a does not match vocab_size ~a"
           (vector-length logits)
           vocab-size))
  (decoded-logits-response
   logits
   vocab-size
   (response-nonnegative-flonum/default response 'elapsed_ms 0.0)
   (response-natural/default response 'prompt_tokens 0)
   (response-natural/default response 'prefix_tokens 0)
   (response-boolean/default response 'cache_hit #f)
   (response-maybe-string response 'session)))

(define (decode-tokenize-response response)
  (check-ok 'tokenize response)
  (define tokens (hash-field response 'tokens))
  (unless (list? tokens)
    (error 'llama-local "tokenize response has no token list: ~s" response))
  (for/list ([token (in-list tokens)])
    (unless (exact-nonnegative-integer? token)
      (error 'llama-local "token id is not a natural number: ~s" token))
    token))

(define (decode-detokenize-response response)
  (check-ok 'detokenize response)
  (response-string response 'text))

(define (decode-logits-list xs)
  (unless (list? xs)
    (error 'decode-logits-response "logits must be a JSON array: ~s" xs))
  (for/vector ([x (in-list xs)])
    (unless (real? x)
      (error 'decode-logits-response "logit is not numeric: ~s" x))
    (real->double-flonum x)))

(define (decode-logits-b64 text)
  (define bytes (base64-decode (string->bytes/utf-8 text)))
  (unless (zero? (remainder (bytes-length bytes) 8))
    (error 'decode-logits-response
           "logits_b64 byte length must be divisible by 8, got ~a"
           (bytes-length bytes)))
  (for/vector ([offset (in-range 0 (bytes-length bytes) 8)])
    (real->double-flonum
     (floating-point-bytes->real bytes #t offset (+ offset 8)))))

(define (check-ok context response)
  (unless (hash? response)
    (error 'llama-local "~a response is not an object: ~s" context response))
  (unless (equal? (hash-field response 'ok) #t)
    (error 'llama-local "~a response is not ok: ~s" context response)))

(define (hash-field table key)
  (hash-ref table key
            (lambda ()
              (hash-ref table (symbol->string key)
                        (lambda ()
                          (error 'llama-local
                                 "response missing field ~a: ~s"
                                 key
                                 table))))))

(define (response-natural response key)
  (define value (hash-field response key))
  (unless (exact-nonnegative-integer? value)
    (error 'llama-local "field ~a must be a natural number: ~s" key value))
  value)

(define (response-natural/default response key default)
  (define value
    (hash-ref response key
              (lambda ()
                (hash-ref response (symbol->string key) (lambda () default)))))
  (unless (exact-nonnegative-integer? value)
    (error 'llama-local "field ~a must be a natural number: ~s" key value))
  value)

(define (response-string response key)
  (define value (hash-field response key))
  (unless (string? value)
    (error 'llama-local "field ~a must be a string: ~s" key value))
  value)

(define (response-string/default response key default)
  (define value
    (hash-ref response key
              (lambda ()
                (hash-ref response (symbol->string key) (lambda () default)))))
  (unless (string? value)
    (error 'llama-local "field ~a must be a string: ~s" key value))
  value)

(define (response-maybe-string response key)
  (define value
    (hash-ref response key
              (lambda ()
                (hash-ref response (symbol->string key) (lambda () #f)))))
  (cond
    [(or (not value) (eq? value 'null)) #f]
    [(string? value) value]
    [else (error 'llama-local "field ~a must be a string or null: ~s" key value)]))

(define (response-nonnegative-flonum/default response key default)
  (define value
    (hash-ref response key
              (lambda ()
                (hash-ref response (symbol->string key) (lambda () default)))))
  (unless (and (real? value) (>= value 0))
    (error 'llama-local "field ~a must be nonnegative: ~s" key value))
  (real->double-flonum value))

(define (response-boolean/default response key default)
  (define value
    (hash-ref response key
              (lambda ()
                (hash-ref response (symbol->string key) (lambda () default)))))
  (unless (boolean? value)
    (error 'llama-local "field ~a must be boolean: ~s" key value))
  value)

(define (model-path->id model-path)
  (define path (path-string->path model-path))
  (define maybe-name (file-name-from-path path))
  (if maybe-name (path->string maybe-name) (path->string path)))

(define (model-path->hash model-path)
  (define path (path-string->path model-path))
  (and (file-exists? path)
       (call-with-input-file path sha1)))

(define (path-string->path value)
  (if (path? value) value (string->path value)))
