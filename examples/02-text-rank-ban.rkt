#lang racket/base

(require rack-llm)

(define provider
  (make-mock-provider
   #:vocab '("patent" "TODO" " note")
   #:default-logits '#(0.0 10.0 0.0)))

(define guide
  (text #:max-tokens 8
        (rank 3 "patent")
        (ban "TODO")))

(define result
  (generate provider "" guide #:beta 2.0 #:seed 3 #:max-tokens 1))

(displayln (generation-result-text result))
