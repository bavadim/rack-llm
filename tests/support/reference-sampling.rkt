#lang typed/racket/base/no-check

(require "logits.rkt" (only-in "../../backend.rkt" factor-selection))
(provide sample-factor-logits)

(define (dead? x) (eqv? x -inf.0))
(define (log-add a b)
  (cond [(dead? b) a] [(dead? a) b]
        [else (define m (max a b)) (+ m (log (+ (exp (- a m)) (exp (- b m)))))]))
(define (gumbel)
  (define u (max 1e-12 (min (- 1.0 1e-12) (random))))
  (- (log (- (log u)))))

(define (sample-factor-logits logits rng temperature log-factor frontier?)
  (unless (> temperature 0.0)
    (raise-argument-error 'sample-factor-logits "positive temperature" temperature))
  (define-values (best-id _score best-tempered log-z frontier-z)
    (parameterize ([current-pseudo-random-generator rng])
      (for/fold ([best-id : (Option Natural) #f] [best-score : Real -inf.0]
                 [best-tempered : Real -inf.0] [log-z : Real -inf.0]
                 [frontier-z : Real -inf.0])
                ([id : Natural (in-range (logits-length logits))])
        (define raw (logits-ref logits id))
        (define tempered (if (dead? raw) -inf.0 (/ raw temperature)))
        (define next-z (log-add log-z tempered))
        (define next-frontier
          (if (and (frontier? id) (not (dead? tempered)))
              (log-add frontier-z tempered) frontier-z))
        (define factor (log-factor id))
        (define score (if (or (dead? tempered) (dead? factor))
                          -inf.0 (+ tempered factor (gumbel))))
        (if (> score best-score)
            (values id score tempered next-z next-frontier)
            (values best-id best-score best-tempered next-z next-frontier)))))
  (and best-id
       (let ([base (- best-tempered log-z)])
         (factor-selection best-id base (exp base)
                           (if (dead? frontier-z) 0.0 (exp (- frontier-z log-z)))))))
