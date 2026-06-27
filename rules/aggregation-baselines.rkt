#lang racket/base

(require rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene)

(provide majority-posterior-like
         equal-weight-score
         baseline-constraint-posteriors)

(define (majority-posterior-like observations)
  (define accepts (count-decision 'accept observations))
  (define rejects (count-decision 'reject observations))
  (cond
    [(> accepts rejects) 1.0]
    [(> rejects accepts) 0.0]
    [else 0.5]))

(define (equal-weight-score observations)
  (define accepts (count-decision 'accept observations))
  (define rejects (count-decision 'reject observations))
  (define denominator (+ accepts rejects))
  (if (zero? denominator)
      0.5
      (/ (exact->inexact accepts) denominator)))

(define (baseline-constraint-posteriors mode observations)
  (define score-fn (baseline-score-fn mode))
  (for/hash ([constraint-id (in-list (collect-constraint-ids observations))])
    (values constraint-id
            (score-fn (constraint-rule-observations constraint-id observations)))))

(define (baseline-score-fn mode)
  (case mode
    [(majority) majority-posterior-like]
    [(equal-weight) equal-weight-score]
    [else (error 'baseline-constraint-posteriors
                 "unsupported aggregation baseline: ~a"
                 mode)]))

(define (count-decision decision observations)
  (for/sum ([observation (in-list observations)])
    (if (eq? decision (rule-observation-decision observation)) 1 0)))

(define (collect-constraint-ids observations)
  (reverse
   (for/fold ([ids '()])
             ([observation (in-list observations)])
     (define constraint-id (constraint-observation-constraint-id observation))
     (if (memq constraint-id ids)
         ids
         (cons constraint-id ids)))))

(define (constraint-rule-observations constraint-id observations)
  (for/list ([observation (in-list observations)]
             #:when (eq? constraint-id
                         (constraint-observation-constraint-id observation)))
    (constraint-observation-rule-observation observation)))
