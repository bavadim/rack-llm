#lang racket/base

(require racket/list
         rackunit
         rack-llm/grammar
         rack-llm/grammar/combinators
         rack-llm/providers/mock-provider
         rack-llm/sampling/gumbel-stream
         rack-llm/sampling/sampler-stats)

(define (make-uniform-provider)
  (make-mock-provider
   #:vocab '("a" "b" "c")
   #:default-logits '#(0.0 0.0 0.0)))

(define finite-matcher
  (compile-matcher
   (choice (lit "a") (list (lit "b") (lit "c")))))

(define (run-texts seed)
  (define-values (ys _stats)
    (collect-gumbel-stream
     (make-uniform-provider)
     finite-matcher
     (gumbel-config 1 3 10 seed 'binary-heap '(tokens))
     '()))
  (map candidate-text ys))

(define gumbel-stream-tests
  (test-suite
   "provider-backed gumbel stream"

   (test-case "finite grammar yields accepting duplicate-free candidates"
     (define-values (ys stats)
       (collect-gumbel-stream
        (make-uniform-provider)
        finite-matcher
        (gumbel-config 1 3 10 42 'binary-heap '(tokens))
        '()))
     (check-equal? (length ys) 3)
     (check-equal? (length (remove-duplicates (map candidate-text ys))) 3)
     (for ([y (in-list ys)])
       (check-true (matcher-accepting? (candidate-matcher-state y))))
     (check-true (> (sampler-stats-expanded-nodes stats) 0))
     (check-true (>= (sampler-stats-agenda-pushes stats)
                     (sampler-stats-agenda-pops stats)))
     (check-equal? (sampler-stats-yielded-candidates stats) 3))

   (test-case "same seed is deterministic"
     (check-equal? (run-texts 123) (run-texts 123)))

   (test-case "different seeds change gumbel priority order"
     (check-not-equal? (run-texts 123) (run-texts 124)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests gumbel-stream-tests))
