#lang typed/racket/base/no-check

(require "logits.rkt" (only-in "../../backend.rkt" factor-selection))
(provide sample-factor-logits)

(define (dead? x) (eqv? x -inf.0))
(define (log-add a b)
  (cond [(dead? b) a] [(dead? a) b]
        [else (define m (max a b)) (+ m (log (+ (exp (- a m)) (exp (- b m)))))]))
(define (sample-factor-logits logits draw temperature log-factor frontier?)
  (unless (> temperature 0.0)
    (raise-argument-error 'sample-factor-logits "positive temperature" temperature))
  (define weighted
    (for/vector ([id : Natural (in-range (logits-length logits))])
      (define base (/ (logits-ref logits id) temperature))
      (define factor (log-factor id))
      (if (or (dead? base) (dead? factor)) -inf.0 (+ base factor))))
  (define log-z
    (for/fold ([z : Real -inf.0]) ([id : Natural (in-range (logits-length logits))])
      (log-add z (/ (logits-ref logits id) temperature))))
  (define frontier-z
    (for/fold ([z : Real -inf.0]) ([id : Natural (in-range (logits-length logits))]
                                   #:when (frontier? id))
      (log-add z (/ (logits-ref logits id) temperature))))
  (define adjusted-z (for/fold ([z : Real -inf.0]) ([x (in-vector weighted)]) (log-add z x)))
  (define target (max 0.0 (min 0.9999999999999999 draw)))
  (define-values (selected _)
    (for/fold ([selected : (Option Natural) #f] [total : Real 0.0])
              ([x (in-vector weighted)] [id : Natural (in-naturals)])
      (define next (+ total (if (dead? x) 0.0 (exp (- x adjusted-z)))))
      (values (or selected (and (> next target) id)) next)))
  (and selected
       (let ([base (- (/ (logits-ref logits selected) temperature) log-z)])
         (factor-selection selected base (exp base)
                           (if (dead? frontier-z) 0.0 (exp (- frontier-z log-z)))))))
