#lang racket/base

(require racket/list
         racket/stream
         json
         rackunit
         rack-llm
         rack-llm/providers/mock-provider
         rack-llm/providers/provider-v2
         rack-llm/traces/metadata
         rack-llm/traces/trace)

(define provider-smoke
  (test-suite
   "provider integration smoke"

   (test-case "mock provider drives a deterministic old-core run"
     (random-seed 7)
     (define p
       (make-mock-provider
        #:vocab '("A" "B")
        #:default-logits '#(0.0 -1000.0)))
     (define result
       (stream-first
        (eval (provider->token-oracle p)
              (list (assistant (gen 1))))))
     (check-equal? (message->string (first result)) "A")
     (check-equal?
      (hash-ref
       (run-metadata->json
        (run-metadata "smoke"
                      7
                      "0.1.0"
                      #f
                      (provider-info-name (provider-info p))
                      'exact
                      (provider-info-model-id (provider-info p))
                      (provider-info-model-hash (provider-info p))
                      "smoke-grammar"
                      "none"))
       'provider_name)
      "mock"))

   (test-case "smoke trace starts with metadata event"
     (random-seed 7)
     (define p
       (make-mock-provider
        #:vocab '("A" "B")
        #:default-logits '#(0.0 -1000.0)))
     (stream-first
      (eval (provider->token-oracle p)
            (list (assistant (gen 1)))))
     (define out (open-output-string))
     (write-trace-event
      out
      'metadata
      (run-metadata "smoke"
                    7
                    "0.1.0"
                    #f
                    (provider-info-name (provider-info p))
                    'exact
                    (provider-info-model-id (provider-info p))
                    (provider-info-model-hash (provider-info p))
                    "smoke-grammar"
                    "none"))
     (define first-event (string->jsexpr (get-output-string out)))
     (check-equal? (hash-ref first-event 'event) "metadata")
     (check-equal? (hash-ref (hash-ref first-event 'payload) 'provider_mode)
                   "exact"))))

(module+ test
  (require rackunit/text-ui)
  (run-tests provider-smoke))
