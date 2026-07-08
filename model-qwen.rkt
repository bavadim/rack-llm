#lang racket/base

(require json
         net/base64
         racket/port
         "main.rkt")

(provide qwen-model)

(struct sidecar (send close) #:transparent)
(define (qwen-model #:model-path model-path
                                #:command [command (getenv "RACK_LLM_LLAMA_SIDECAR")]
                                #:context-size [context-size 512]
                                #:threads [threads 1]
                                #:seed [seed 0])
  (unless command
    (error 'qwen-model
           "expected #:command or RACK_LLM_LLAMA_SIDECAR"))
  (define process (open-qwen-sidecar command))
  (define load-response
    (sidecar-request
     process
     (hash 'op "load"
           'model_path (path->string (if (path? model-path)
                                         model-path
                                         (string->path model-path)))
           'context_size context-size
           'threads threads
           'seed seed)))
  (check-ok 'load load-response)
  (define vocab (response-list load-response 'vocab))
  (unless (andmap string? vocab)
    (error 'qwen-model
           "load response field vocab must be a list of strings"))
  (define vocab-vector (list->vector vocab))
  (define tok
    (tokenizer
     #:fingerprint (format "qwen:~a" model-path)
     #:vocab-size (vector-length vocab-vector)
     #:token-ref
     (lambda (id)
       (vector-ref vocab-vector id))
     #:tokenize
     (lambda (text)
       (define response
         (sidecar-request
          process
          (hash 'op "tokenize"
                'text text)))
       (check-ok 'tokenize response)
       (response-token-ids response 'ids))
     #:detokenize
     (lambda (ids)
       (define response
         (sidecar-request
          process
          (hash 'op "detokenize"
                'ids ids)))
       (check-ok 'detokenize response)
       (response-string response 'text))))
  (define llm-provider
    (provider
     #:vocab-size (length vocab)
     #:mode 'exact-full-vocab
     #:metadata (hash 'name 'qwen-sidecar
                     'model-path model-path)
     #:next-logits
     (lambda (prompt-ids prefix-ids)
       (define response
         (sidecar-request
          process
          (hash 'op "next_logits"
                'prompt (detokenize tok prompt-ids)
                'prefix (detokenize tok prefix-ids))))
       (check-ok 'next_logits response)
       (define logits (decode-logits response))
       (unless (= (vector-length logits) (length vocab))
         (error 'qwen-model
                "sidecar returned ~a logits for ~a vocabulary items"
                (vector-length logits)
                (length vocab)))
       logits)
     #:start-session
     (lambda (prompt-ids)
       (define response
         (sidecar-request
          process
          (hash 'op "start"
                'prompt (detokenize tok prompt-ids))))
       (check-ok 'start response)
       response)
     #:next-logits/session
     (lambda (session)
       (define response
         (sidecar-request
          process
          (session-request session (hash 'op "next_logits"))))
       (check-ok 'next_logits/session response)
       (define logits (decode-logits response))
       (unless (= (vector-length logits) (length vocab))
         (error 'qwen-model
                "sidecar returned ~a session logits for ~a vocabulary items"
                (vector-length logits)
                (length vocab)))
       logits)
     #:commit-token!
     (lambda (session token-id)
       (define response
         (sidecar-request
          process
          (session-request session
                           (hash 'op "commit"
                                 'token_id token-id))))
       (check-ok 'commit response)
       (void))
     #:end-session!
     (lambda (session)
       (define response
         (sidecar-request
          process
          (session-request session (hash 'op "end"))))
       (check-ok 'end response)
       (void))))
  (model tok llm-provider (hash 'name 'qwen 'model-path model-path) (lambda () (close-qwen-sidecar process))))

(define (open-qwen-sidecar command)
  (define-values (proc stdout stdin stderr)
    (subprocess #f #f #f "/bin/sh" "-c" command))
  (define lock (make-semaphore 1))
  (sidecar
   (lambda (payload)
     (call-with-semaphore
      lock
      (lambda ()
        (write-json payload stdin)
        (newline stdin)
        (flush-output stdin)
        (define line (read-line stdout 'any))
        (when (eof-object? line)
          (error 'qwen-sidecar
                 "sidecar closed stdout: ~a"
                 (port->string stderr)))
        (string->jsexpr line))))
   (lambda ()
     (with-handlers ([exn:fail? void])
       (write-json (hash 'op "close") stdin)
       (newline stdin)
       (flush-output stdin))
     (close-output-port stdin)
     (subprocess-wait proc))))

(define (close-qwen-sidecar process)
  ((sidecar-close process)))

(define (sidecar-request process payload)
  ((sidecar-send process) payload))

(define (session-request session payload)
  (define session-id
    (cond
      [(hash-has-key? session 'session_id) (hash-ref session 'session_id)]
      [(hash-has-key? session "session_id") (hash-ref session "session_id")]
      [else #f]))
  (if session-id
      (hash-set payload 'session_id session-id)
      payload))

(define (decode-logits response)
  (cond
    [(hash-has-key? response 'logits)
     (decode-logits-list (hash-ref response 'logits))]
    [(hash-has-key? response "logits")
     (decode-logits-list (hash-ref response "logits"))]
    [else
     (decode-logits-b64 (response-string response 'logits_b64))]))

(define (decode-logits-list xs)
  (unless (list? xs)
    (error 'decode-logits "logits must be a JSON array: ~s" xs))
  (for/vector ([x (in-list xs)])
    (unless (real? x)
      (error 'decode-logits "logit is not numeric: ~s" x))
    (exact->inexact x)))

(define (decode-logits-b64 text)
  (define bytes (base64-decode (string->bytes/utf-8 text)))
  (unless (zero? (remainder (bytes-length bytes) 8))
    (error 'decode-logits
           "logits_b64 byte length must be divisible by 8, got ~a"
           (bytes-length bytes)))
  (for/vector ([offset (in-range 0 (bytes-length bytes) 8)])
    (floating-point-bytes->real bytes #t offset (+ offset 8))))

(define (check-ok who response)
  (unless (hash? response)
    (error who "sidecar response is not an object: ~s" response))
  (unless (equal? (hash-field response 'ok) #t)
    (error who "sidecar response is not ok: ~s" response)))

(define (hash-field table key)
  (hash-ref table key
            (lambda ()
              (hash-ref table (symbol->string key)
                        (lambda ()
                          (error 'qwen-model
                                 "response missing field ~a: ~s"
                                 key
                                 table))))))

(define (response-string response key)
  (define value (hash-field response key))
  (unless (string? value)
    (error 'qwen-model "field ~a must be a string: ~s" key value))
  value)

(define (response-list response key)
  (define value (hash-field response key))
  (unless (list? value)
    (error 'qwen-model "field ~a must be a list: ~s" key value))
  value)

(define (response-token-ids response key)
  (define value (response-list response key))
  (unless (andmap exact-nonnegative-integer? value)
    (error 'qwen-model "field ~a must be a list of token ids: ~s" key value))
  value)
