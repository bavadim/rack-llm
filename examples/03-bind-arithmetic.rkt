#lang racket/base

(require rack-llm)

(define provider
  (make-mock-provider
   #:vocab '("2" " sum=3")
   #:default-logits '#(0.0 0.0)))

(define guide
  (bind (pure 2)
        (lambda (n)
          (seq "2" (format " sum=~a" (add1 n))))))

(define result
  (generate provider "" guide))

(displayln (generation-result-text result))
