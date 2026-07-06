#lang racket/base

(require rack-llm)

(define provider
  (make-mock-provider
   #:vocab '("Answer: " "yes" "no" "maybe")
   #:default-logits '#(0.0 0.0 0.1 10.0)))

(define guide
  (seq "Answer: " (select "yes" "no")))

(define result
  (generate provider "" guide))

(displayln (generation-result-text result))
