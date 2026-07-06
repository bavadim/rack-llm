#lang racket/base

(require rack-llm)

(define learned
  (weight #:data '("patent granted"
                   "patent claim"
                   "unknown null"
                   "TODO unknown")
          (rank 1 "patent")
          (rank -1 "unknown")))

(define provider
  (make-mock-provider
   #:vocab '("patent" "unknown")
   #:default-logits '#(0.0 0.0)))

(define result
  (generate provider "" (text learned) #:beta 2.0 #:seed 3 #:max-tokens 1))

(displayln (generation-result-text result))
