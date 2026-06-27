#lang racket/base

(require racket/list
         racket/stream
         rackunit
         rack-llm
         rack-llm/providers/mock-provider
         rack-llm/providers/provider-v2
         rack-llm/providers/prompt-rendering
         rack-llm/testing)

(define provider-v2-tests
  (test-suite
   "provider v2"

   (test-case "mock provider exposes full logits and deterministic tokenization"
     (define p
       (make-mock-provider
        #:vocab '("a" "b")
        #:default-logits '#(0.0 -1.0)))
     (define r ((provider-next-logits p) '() "" (provider-initial-state p)))
     (check-equal? (vector-length (logits-result-logits r)) 2)
     (check-equal? ((provider-tokenize p) "ab") '(0 1))
     (check-equal? ((provider-detokenize p) '(0 1)) "ab")
     (check-equal? (provider-info-mode (provider-info p)) 'exact-full-vocab))

   (test-case "mock provider can dispatch by prefix"
     (define p
       (make-mock-provider
        #:vocab '("a" "b" "<eos>")
        #:default-logits '#(0.0 0.0 -10.0)
        #:prefix-logits (hash "a" '#(-10.0 0.0 0.0))))
     (define r
       ((provider-next-logits p) '() "a" (provider-initial-state p)))
     (check-equal? (vector-ref (logits-result-logits r) 1) 0.0)
     (check-equal? (provider-trace-prefix-tokens (logits-result-trace r)) 1))

   (test-case "testing helper aliases deterministic mock provider"
     (define p
       (make-deterministic-mock-provider
        #:vocab '("x")
        #:default-logits '#(0.0)))
     (check-equal? ((provider-tokenize p) "x") '(0))
     (check-stream-prefix (in-list '(a b c)) '(a b)))

   (test-case "plain renderer is shared and role-aware"
     (check-equal?
      (plain-renderer (list (message 'user (list (lit "hi")))) "prefix")
      "user: hi\nprefix"))

   (test-case "compatibility adapter is not exact"
     (define oracle
       (lambda (_transcript prefix)
         (if (string=? prefix "")
             (list (token-candidate "a" -0.2)
                   (token-candidate "b" -1.0))
             '())))
     (define p
       (token-oracle->provider oracle
                               #:name 'legacy
                               #:model-id "legacy"
                               #:vocab '("a" "b")))
     (define r ((provider-next-logits p) '() "" (provider-initial-state p)))
     (check-equal? (provider-info-mode (provider-info p)) 'compat-no-logits)
     (check-equal? (vector->list (logits-result-logits r)) '(-0.2 -1.0))
     (check-exn #rx"compat-no-logits cannot be used for exact distribution tests"
                (lambda () (require-exact-provider p))))

   (test-case "truncate provider masks non-top-k logits and records discarded mass"
     (define p
       (make-mock-provider
        #:vocab '("a" "b" "c")
        #:default-logits '#(2.0 1.0 0.0)))
     (define truncated (truncate-provider p 2))
     (define r
       ((provider-next-logits truncated) '() "" (provider-initial-state truncated)))
     (check-equal? (provider-info-mode (provider-info truncated)) 'truncated-top-k)
     (check-equal? (vector-ref (logits-result-logits r) 2) -inf.0)
     (check-true
      (let ([mass (provider-trace-truncated-mass (logits-result-trace r))])
        (and mass (<= 0.0 mass 1.0)))))

   (test-case "provider-to-token-oracle adapter works with sampler"
     (random-seed 42)
     (define p
       (make-mock-provider
        #:vocab '("o" "k")
        #:default-logits '#(0.0 -1000.0)
        #:prefix-logits (hash "o" '#(-1000.0 0.0))))
     (define result
       (stream-first
        (eval (provider->token-oracle p)
              (list (assistant (gen 1))))))
     (check-equal? (message->string (first result)) "o"))

   (test-case "mock provider drives a select grammar"
     (random-seed 99)
     (define p
       (make-mock-provider
        #:vocab '("a" "b")
        #:default-logits '#(-1000.0 0.0)))
     (define choice (select (list (lit "a")) (list (list (lit "b")))))
     (define result
       (stream-first
        (eval (provider->token-oracle p)
              (list (assistant choice)))))
     (check-equal? (message->string (first result)) "b"))))

(module+ test
  (require rackunit/text-ui)
  (run-tests provider-v2-tests))
