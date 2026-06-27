#lang racket/base

(require rackunit
         rack-llm/experiments/synthetic/gumbel-correctness)

(define synthetic-gumbel-tests
  (test-suite
   "synthetic gumbel correctness metrics"

   (test-case "TV and KL are zero for identical distributions"
     (define p (hash "a" 0.25 "b" 0.75))
     (check-= (total-variation p p) 0.0 1e-9)
     (check-= (kl-divergence p p) 0.0 1e-9))

   (test-case "small benchmark returns rows with no duplicates"
     (define rows (run-synthetic-correctness #:seed 42 #:runs 20))
     (check-equal? (length rows) 3)
     (for ([row (in-list rows)])
       (check-equal? (hash-ref row 'duplicate_rate) 0)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests synthetic-gumbel-tests))
