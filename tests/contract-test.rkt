#lang racket/base
(require racket/runtime-path rackunit "../main.rkt")
(define-runtime-path core "../main.rkt")
(define-runtime-path extension "../backend.rkt")
(define (exported module name)
  (with-handlers ([exn:fail? (lambda (_) 'missing)])
    (dynamic-require module name (lambda () 'missing))))
(module+ test
  (test-case "compact public API"
    (for ([name '(backend-close! llama-cpp-backend lit ere seq choice repeat text
                  rule-set with-rules positive negative compile-spec attach-calibration
                  accepts? observe observe-token-ids observation? observation-schema
                  observation-labels observation->datum datum->observation
                  fit-calibration calibration-posterior calibration-fingerprint
                  calibration-diagnostics save-calibration load-calibration
                  generation-request generate-batch
                  generation-result-status generation-result-reason generation-result-token-ids
                  generation-result-text generation-result-lm-logprob
                  generation-result-latency-ms generation-result-tokenizer-fingerprint
                  generation-result-posterior generation-result-terminal-mass
                  generation-result-calibration-fingerprint generation-result-attempts
                  generation-result-proposed-tokens
                  generation-result-model-draws generation-result-trie-nodes)])
      (check-not-equal? (exported core name) 'missing (symbol->string name)))
    (for ([name '(rx ban control prefer avoid cars-sampler make-generation-request generate
                  observe-text fit-weak-model weak-posterior weak-model-fingerprint
                  weak-model-diagnostics save-weak-model load-weak-model
                  compiled-spec-schema-fingerprint model-close! llama-cpp-model)])
      (check-equal? (exported core name) 'missing (symbol->string name))))
  (test-case "backend extension is public"
    (for ([name '(make-tokenizer make-provider make-backend backend-close!
                  factor-request-temperature factor-request-domain factor-request-constrain?
                  factor-request-children factor-request-draw factor-selection domain-member?)])
      (check-not-equal? (exported extension name) 'missing (symbol->string name))))
  (test-case "removed backend internals stay private"
    (for ([name '(factor-request tokenize detokenize token-ref vocab-size
                  tokenizer-fingerprint make-rng factor-selection? factor-selection-id)])
      (check-equal? (exported extension name) 'missing (symbol->string name))))
  (test-case "ERE portable grammar"
    (for ([p '("US[0-9]+" "(a|b){1,3}" "^a.*b$" "[^x]" "a\\+b")])
      (check-not-exn (lambda () (ere p)) p))
    (for ([p '("(?i)a" "(?=a)b" "\\d+" "\\bword\\b" "(a)\\1" "a*?")])
      (check-exn #rx"ere" (lambda () (ere p)) p)))
  (test-case "constructors validate"
    (check-exn exn:fail? (lambda () (seq)))
    (check-exn exn:fail? (lambda () (choice)))
    (check-exn #rx"lit or ere" (lambda () (positive "bad" (text 2))))))
