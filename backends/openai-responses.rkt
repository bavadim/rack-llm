#lang typed/racket/base

(require racket/port
         typed/json
         typed/net/url
         "../providers/prompt-rendering.rkt"
         "../providers/provider-v2.rkt"
         "../main.rkt")

(provide make-openai-responses-llm
         make-openai-compat-provider)

(define-type Prompt String)
(define-type TokenDistribution (Listof token-candidate))
(define-type ResponseJSON JSExpr)

(struct response-params
  ([model : String]
   [top-logprobs : Natural]
   [max-output-tokens : Natural])
  #:transparent)
(define-type ResponseParams response-params)

(struct response-request
  ([prompt : Prompt]
   [params : ResponseParams])
  #:transparent)
(define-type ResponseRequest response-request)

(define-type ResponseClient (-> ResponseRequest ResponseJSON))

(: make-openai-responses-llm (->* () (#:api-key String
                                      #:base-url String
                                      #:model String
                                      #:top-logprobs Natural
                                      #:max-output-tokens Natural
                                      #:client (Option ResponseClient))
                                   TokenOracle))
(define (make-openai-responses-llm
         #:api-key [api-key (or (getenv "OPENAI_API_KEY") "")]
         #:base-url [base-url "https://api.openai.com/v1"]
         #:model [model "gpt-5.4-nano"]
         #:top-logprobs [top-logprobs 20]
         #:max-output-tokens [max-output-tokens 16]
         #:client [client #f])
  (when (and (not client) (string=? api-key ""))
    (error 'openai-responses "missing API key; pass #:api-key or set OPENAI_API_KEY"))
  (define response-client : ResponseClient
    (or client (http-response-client base-url api-key)))
  (token-oracle response-client (response-params model top-logprobs max-output-tokens)))

(: make-openai-compat-provider (->* () (#:api-key String
                                        #:base-url String
                                        #:model String
                                        #:top-logprobs Natural
                                        #:max-output-tokens Natural
                                        #:client (Option ResponseClient)
                                        #:vocab (Listof String))
                                     Provider))
(define (make-openai-compat-provider
         #:api-key [api-key (or (getenv "OPENAI_API_KEY") "")]
         #:base-url [base-url "https://api.openai.com/v1"]
         #:model [model "gpt-5.4-nano"]
         #:top-logprobs [top-logprobs 20]
         #:max-output-tokens [max-output-tokens 16]
         #:client [client #f]
         #:vocab [vocab '()])
  (token-oracle->provider
   (make-openai-responses-llm
    #:api-key api-key
    #:base-url base-url
    #:model model
    #:top-logprobs top-logprobs
    #:max-output-tokens max-output-tokens
    #:client client)
   #:name 'openai-responses
   #:model-id model
   #:vocab vocab
   #:mode 'truncated-top-k))

(: token-oracle (-> ResponseClient ResponseParams TokenOracle))
(define (token-oracle client params)
  (lambda ([transcript : EvaluatedProgram] [prefix : String])
    (response-token-distribution
     (client (response-request (oracle-prompt transcript prefix) params)))))

(: http-response-client (-> String String ResponseClient))
(define (http-response-client base-url api-key)
  (define endpoint (responses-endpoint base-url))
  (lambda ([request : ResponseRequest])
    (post-json endpoint api-key (response-request->jsexpr request))))

(: responses-endpoint (-> String URL))
(define (responses-endpoint base-url)
  (string->url (string-append (regexp-replace #rx"/+$" base-url "") "/responses")))

(: post-json (-> URL String JSExpr JSExpr))
(define (post-json endpoint api-key body)
  (define in
    (post-pure-port endpoint
                    (string->bytes/utf-8 (jsexpr->string body))
                    (list "Content-Type: application/json"
                          (string-append "Authorization: Bearer " api-key))))
  (define response (port->string in))
  (close-input-port in)
  (string->jsexpr response))

(: response-request->jsexpr (-> ResponseRequest JSExpr))
(define (response-request->jsexpr request)
  (define params (response-request-params request))
  (hash 'model (response-params-model params)
        'input (response-request-prompt request)
        'max_output_tokens (response-params-max-output-tokens params)
        'store #f
        'include (list "message.output_text.logprobs")
        'top_logprobs (response-params-top-logprobs params)))

(: oracle-prompt (-> EvaluatedProgram String Prompt))
(define (oracle-prompt transcript prefix)
  (plain-renderer transcript prefix))

(: response-token-distribution (-> ResponseJSON TokenDistribution))
(define (response-token-distribution js)
  (define entries (first-top-logprobs js))
  (map decode-token-candidate entries))

(: first-top-logprobs (-> Any (Listof Any)))
(define (first-top-logprobs js)
  (define candidates
    (filter list? (collect-field js 'top_logprobs)))
  (cond
    [(null? candidates)
     (error 'openai-responses "server response has no top_logprobs: ~s" js)]
    [else (assert (car candidates) list?)]))

(: collect-field (-> Any Symbol (Listof Any)))
(define (collect-field js key)
  (append (direct-field js key)
          (cond
            [(hash? js)
             (apply append
                    (for/list : (Listof (Listof Any)) ([v (in-list (hash-values js))])
                      (collect-field v key)))]
            [(list? js)
             (apply append
                    (for/list : (Listof (Listof Any)) ([v (in-list js)])
                      (collect-field v key)))]
            [else '()])))

(: direct-field (-> Any Symbol (Listof Any)))
(define (direct-field js key)
  (cond
    [(hash? js)
     (define value
       (hash-ref js key
                 (lambda ()
                   (hash-ref js (symbol->string key) (lambda () #f)))))
     (if value (list value) '())]
    [else '()]))

(: decode-token-candidate (-> Any token-candidate))
(define (decode-token-candidate entry)
  (unless (hash? entry)
    (error 'openai-responses "malformed token probability: ~s" entry))
  (define token (or (js-field entry 'token)
                    (js-field entry 'text)))
  (define logprob (js-field entry 'logprob))
  (unless (and (string? token) (real? logprob))
    (error 'openai-responses "malformed token probability: ~s" entry))
  (token-candidate token (real->double-flonum logprob)))

(: js-field (-> Any Symbol Any))
(define (js-field obj key)
  (and (hash? obj)
       (hash-ref obj key
                 (lambda ()
                   (hash-ref obj (symbol->string key) (lambda () #f))))))
