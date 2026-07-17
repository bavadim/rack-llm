#lang racket/base

(require rackunit
         "../support/logits.rkt"
         "../../private/model.rkt"
         "../support/reference-sampling.rkt")

(module+ test
  (test-case "factor sampling reports exact base and frontier mass"
    (define logits (vector->logits-view (vector (log 0.4) (log 0.3) (log 0.2) (log 0.1))))
    (define selected
      (sample-factor-logits logits (make-rng 7) 1.0
                            (lambda (id) (if (= id 0) (log 0.5) 0.0))
                            (lambda (id) (< id 2))))
    (check-not-false selected)
    (check-= (factor-selection-frontier-mass selected) 0.7 1e-12)
    (check-= (factor-selection-base-probability selected)
             (vector-ref #(0.4 0.3 0.2 0.1) (factor-selection-id selected))
             1e-12)))
