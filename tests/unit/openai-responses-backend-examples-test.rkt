#lang racket/base

(require racket/stream
         rackunit
         rack-llm
         rack-llm/providers/provider-v2
         rack-llm/backends/openai-responses)

(define openai-responses-backend-examples
  (test-suite
   "OpenAI Responses backend examples"

   (test-case "backend requests one token with top logprobs"
     (define captured-requests (box '()))
     (define (fake-client request)
       (set-box! captured-requests (cons request (unbox captured-requests)))
       (hash 'output
             (list
              (hash 'type "message"
                    'content
                    (list
                     (hash 'type "output_text"
                           'text "ab"
	                           'logprobs
	                           (list
	                            (hash 'token "ab"
	                                  'logprob -0.1
	                                  'top_logprobs
	                                  (list
	                                   (hash 'token "ab" 'logprob -0.1))))))))))

     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define complete
       (make-openai-responses-llm
        #:model "test-model"
        #:top-logprobs 2
        #:client fake-client))
     (check-true (procedure? complete))

     (define result
       (stream-first
        (eval complete
              (list
               (system (lit "You are concise."))
               (assistant choice)))))

     (check-equal?
      result
      (list (message 'system (list (lit "You are concise.")))
            (message 'assistant
                     (list (selected choice (list (lit "ab")))))))
     (check-equal? (length (unbox captured-requests)) 1))

   (test-case "compat provider is explicitly truncated"
     (define p
       (make-openai-compat-provider
        #:model "test-model"
        #:top-logprobs 2
        #:client (lambda (_request) (hash 'output '()))))
     (check-equal? (provider-info-mode (provider-info p)) 'truncated-top-k)
     (check-exn #rx"truncated-top-k cannot be used for exact distribution tests"
                (lambda () (require-exact-provider p))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests openai-responses-backend-examples))
