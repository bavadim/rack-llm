#lang typed/racket/base

(require typed/json
         typed/net/url
         racket/port
         "../main.rkt")

(provide make-llama-cpp-model)

(: make-llama-cpp-model (->* () (#:model String #:base-url String #:api-key String) chat-model))
(define (make-llama-cpp-model
         #:model [model-name "llama.cpp"]
         #:base-url [base-url "http://localhost:8080/v1"]
         #:api-key [api-key (or (getenv "LLAMA_API_KEY") "EMPTY")])
  (define endpoint
    (string->url
     (string-append (strip-trailing-slashes base-url)
                    "/chat/completions")))

  (: complete (-> request String))
  (define (complete req)
    (define payload
      (hash-set-present
       (hash-set-present
        (hash 'model model-name
              'messages (map chat-message->jsexpr (request-messages req)))
        'max_tokens (request-max-tokens req))
       'grammar (request-grammar req)))
    (define headers
      (list "Content-Type: application/json"
            (format "Authorization: Bearer ~a" api-key)))
    (define in
      (post-pure-port endpoint
                      (string->bytes/utf-8 (jsexpr->string (cast payload JSExpr)))
                      headers))
    (define raw (port->string in))
    (close-input-port in)
    (response->text (string->jsexpr raw)))

  (make-chat-model complete #:name model-name))

(: chat-message->jsexpr (-> chat-message JSExpr))
(define (chat-message->jsexpr msg)
  (hash 'role (symbol->string (chat-message-role msg))
        'content (chat-message-content msg)))

(: strip-trailing-slashes (-> String String))
(define (strip-trailing-slashes s)
  (regexp-replace #px"/+$" s ""))

(: hash-set-present (-> (Immutable-HashTable Symbol Any) Symbol Any (Immutable-HashTable Symbol Any)))
(define (hash-set-present h k v)
  (if v (hash-set h k v) h))

(define missing (gensym 'missing))

(: json-ref (->* (Any Symbol) (Any) Any))
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
       [else (fail)])]
    [else (fail)]))

(: response->text (-> JSExpr String))
(define (response->text js)
  (define choices (json-ref js 'choices))
  (define choice
    (cond
      [(pair? choices) (car choices)]
      [(and (vector? choices) (> (vector-length choices) 0))
       (vector-ref choices 0)]
      [else (error 'llama-cpp "response has no choices: ~s" js)]))
  (define content (json-ref (json-ref choice 'message) 'content ""))
  (unless (string? content)
    (error 'llama-cpp "message content is not a string: ~s" content))
  content)
