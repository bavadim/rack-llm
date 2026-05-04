#lang racket/base

(require json
         net/url
         racket/list
         racket/port
         racket/string
         "../core.rkt")

(provide make-openai-compatible-model)

(define (strip-trailing-slashes s)
  (regexp-replace #px"/+$" s ""))

(define (hash-merge . hashes)
  (for/fold ([acc (hash)]) ([h (in-list hashes)])
    (for/fold ([acc* acc]) ([(k v) (in-hash h)])
      (hash-set acc* k v))))

(define (hash-set-present h k v)
  (if v (hash-set h k v) h))

(define missing (gensym 'missing))

(define (json-ref obj key [default missing])
  (define (fail)
    (if (eq? default missing)
        (error 'json-ref "missing key ~a in ~s" key obj)
        default))
  (cond
    [(hash? obj)
     (cond
       [(hash-has-key? obj key) (hash-ref obj key)]
       [(and (symbol? key) (hash-has-key? obj (symbol->string key)))
        (hash-ref obj (symbol->string key))]
       [(and (string? key) (hash-has-key? obj (string->symbol key)))
        (hash-ref obj (string->symbol key))]
       [else (fail)])]
    [else (fail)]))

(define (seq-first xs)
  (cond
    [(pair? xs) (car xs)]
    [(and (vector? xs) (> (vector-length xs) 0)) (vector-ref xs 0)]
    [else (error 'seq-first "expected non-empty list/vector, got ~s" xs)]))

(define (openai-compatible-response->text js)
  (define choice (seq-first (json-ref js 'choices)))
  (define message (json-ref choice 'message))
  (json-ref message 'content ""))

(define (make-openai-compatible-model
         #:model model-name
         #:base-url [base-url "https://api.openai.com/v1"]
         #:api-key [api-key (getenv "OPENAI_API_KEY")]
         #:organization [organization #f]
         #:project [project #f]
         #:default-extra [default-extra (hash)])
  (unless api-key
    (error 'make-openai-compatible-model
           "missing API key; pass #:api-key or set OPENAI_API_KEY"))

  (define endpoint
    (string->url
     (string-append (strip-trailing-slashes base-url)
                    "/chat/completions")))

  (define (complete messages
                    #:max-tokens [max-tokens #f]
                    #:temperature [temperature #f]
                    #:stop [stop #f]
                    #:extra [extra (hash)])
    (define payload0
      (hash 'model model-name
            'messages messages))
    (define payload1 (hash-set-present payload0 'max_tokens max-tokens))
    (define payload2 (hash-set-present payload1 'temperature temperature))
    (define payload3 (hash-set-present payload2 'stop stop))
    (define payload (hash-merge default-extra extra payload3))

    (define body (string->bytes/utf-8 (jsexpr->string payload)))
    (define headers
      (filter values
              (list
               "Content-Type: application/json"
               (format "Authorization: Bearer ~a" api-key)
               (and organization (format "OpenAI-Organization: ~a" organization))
               (and project (format "OpenAI-Project: ~a" project)))))

    (define in (post-pure-port endpoint body headers))
    (define raw (port->string in))
    (close-input-port in)

    (define js (string->jsexpr raw))
    (openai-compatible-response->text js))

  (make-chat-model complete #:name model-name))
