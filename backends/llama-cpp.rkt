#lang typed/racket/base

(require racket/port
         racket/string
         typed/json
         typed/net/url
         "../main.rkt")

(provide make-llama-cpp-llm)

(define-type Prompt String)
(define-type TokenDistribution (Listof token-candidate))
(define-type TokenGenerator (-> Prompt TokenDistribution))
(define-type CompletionResponse JSExpr)

(struct completion-params
  ([n-probs : Natural]
   [temperature : Flonum])
  #:transparent)
(define-type CompletionParams completion-params)

(struct completion-request
  ([prompt : Prompt]
   [params : CompletionParams])
  #:transparent)
(define-type CompletionRequest completion-request)

(define-type CompletionClient (-> CompletionRequest CompletionResponse))

(: make-llama-cpp-llm (->* () (#:server-url String
                               #:n-probs Natural
                               #:temperature Flonum
                               #:generate (Option TokenGenerator))
                            TokenOracle))
(define (make-llama-cpp-llm
         #:server-url [server-url (or (getenv "RACK_LLM_LLAMA_SERVER")
                                      "http://localhost:8080")]
         #:n-probs [n-probs 64]
         #:temperature [temperature 0.8]
         #:generate [generate #f])
  (define next-token-distribution : TokenGenerator
    (or generate (llama-cpp-token-generator
                  server-url
                  (completion-params n-probs temperature))))
  (token-oracle next-token-distribution))

;; Token oracle

(: token-oracle (-> TokenGenerator TokenOracle))
(define (token-oracle next-token-distribution)
  (lambda ([transcript : EvaluatedProgram] [prefix : String])
    (next-token-distribution (oracle-prompt transcript prefix))))

(: llama-cpp-token-generator (-> String CompletionParams TokenGenerator))
(define (llama-cpp-token-generator server-url params)
  (completion-token-generator
   (http-completion-client server-url)
   params))

(: completion-token-generator (-> CompletionClient CompletionParams TokenGenerator))
(define (completion-token-generator client params)
  (lambda ([prompt : String])
    (decode-completion-response (client (completion-request prompt params)))))

;; Completion client

(: http-completion-client (-> String CompletionClient))
(define (http-completion-client server-url)
  (define endpoint (completion-endpoint server-url))
  (lambda ([request : CompletionRequest])
    (post-json endpoint (completion-request->jsexpr request))))

(: completion-endpoint (-> String URL))
(define (completion-endpoint server-url)
  (string->url (string-append (regexp-replace #rx"/+$" server-url "") "/completion")))

(: post-json (-> URL JSExpr JSExpr))
(define (post-json endpoint body)
  (define in
    (post-pure-port endpoint
                    (string->bytes/utf-8 (jsexpr->string body))
                    (list "Content-Type: application/json")))
  (define response (port->string in))
  (close-input-port in)
  (string->jsexpr response))

(: completion-request->jsexpr (-> CompletionRequest JSExpr))
(define (completion-request->jsexpr request)
  (define params (completion-request-params request))
  (hash 'prompt (completion-request-prompt request)
        'n_predict 1
        'n_probs (completion-params-n-probs params)
        'temperature (completion-params-temperature params)
        'top_k 0
        'top_p 1.0
        'min_p 0.0
        'cache_prompt #t
        'return_tokens #t
        'response_fields
        (list "completion_probabilities")))

;; Prompt rendering

(: oracle-prompt (-> EvaluatedProgram String Prompt))
(define (oracle-prompt transcript prefix)
  (prompt+prefix (render-transcript transcript) prefix))

(: prompt+prefix (-> Prompt String Prompt))
(define (prompt+prefix prompt prefix)
  (cond
    [(string=? prompt "") prefix]
    [(string=? prefix "") prompt]
    [else (string-append prompt "\n" prefix)]))

(: render-transcript (-> EvaluatedProgram Prompt))
(define (render-transcript messages)
  (string-join
   (for/list : (Listof String) ([msg (in-list messages)])
     (format "~a: ~a"
             (symbol->string (message-role msg))
             (message->string msg)))
   "\n"))

;; Response decoding

(: decode-completion-response (-> CompletionResponse TokenDistribution))
(define (decode-completion-response js)
  (map decode-token-candidate (response-top-logprobs js)))

(: response-top-logprobs (-> CompletionResponse (Listof Any)))
(define (response-top-logprobs js)
  (define probs
    (js-field js 'completion_probabilities))
  (unless (and (list? probs) (pair? probs))
    (error 'llama-cpp "server response has no completion_probabilities: ~s" js))
  (define first-token (car probs))
  (unless (hash? first-token)
    (error 'llama-cpp "malformed completion_probabilities: ~s" js))
  (define top-logprobs (js-field first-token 'top_logprobs))
  (unless (list? top-logprobs)
    (error 'llama-cpp "server response has no top_logprobs: ~s" js))
  top-logprobs)

(: decode-token-candidate (-> Any token-candidate))
(define (decode-token-candidate entry)
  (unless (hash? entry)
    (error 'llama-cpp "malformed token probability: ~s" entry))
  (define token (js-field entry 'token))
  (define logprob (js-field entry 'logprob))
  (unless (and (string? token) (real? logprob))
    (error 'llama-cpp "malformed token probability: ~s" entry))
  (token-candidate token (real->double-flonum logprob)))

(: js-field (-> Any Symbol Any))
(define (js-field obj key)
  (and (hash? obj)
       (hash-ref obj key
                 (lambda ()
                   (hash-ref obj (symbol->string key) (lambda () #f))))))
