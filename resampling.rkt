#lang racket/base

(require racket/stream
         rack-llm/rules/threshold-acceptance
         rack-llm/traces/trace)

(provide (struct-out resampling-config)
         (struct-out resampling-result)
         resample-until-accepted)

(struct resampling-config
  (candidate-budget
   node-budget
   time-budget-ms
   on-fail)
  #:transparent)

(struct resampling-result
  (status
   selected
   selected-rank
   checked
   trace)
  #:transparent)

(struct best-candidate
  (candidate
   rank
   score)
  #:transparent)

(define (resample-until-accepted config candidates decide)
  (define started-ms (current-inexact-milliseconds))
  (let loop ([remaining (sequence->stream candidates)]
             [rank 1]
             [checked 0]
             [trace '()]
             [best #f])
    (cond
      [(or (stream-empty? remaining)
           (budget-exhausted? config checked)
           (time-exhausted? config started-ms))
       (failed-result config checked trace best)]
      [else
       (define candidate (stream-first remaining))
       (define decision (decide candidate))
       (define next-checked (add1 checked))
       (define next-trace
         (cons (candidate->trace rank candidate decision) trace))
       (define next-best (update-best best candidate rank decision))
       (cond
         [(acceptance-decision-accepted? decision)
          (resampling-result 'accepted
                             candidate
                             rank
                             next-checked
                             (reverse next-trace))]
         [else
          (loop (stream-rest remaining)
                (add1 rank)
                next-checked
                next-trace
                next-best)])])))

(define (budget-exhausted? config checked)
  (or (>= checked (resampling-config-candidate-budget config))
      (>= checked (resampling-config-node-budget config))))

(define (time-exhausted? config started-ms)
  (>= (- (current-inexact-milliseconds) started-ms)
      (resampling-config-time-budget-ms config)))

(define (failed-result config checked trace best)
  (cond
    [(and (eq? (resampling-config-on-fail config) 'return-best-by-score)
          best)
     (resampling-result 'failed
                        (best-candidate-candidate best)
                        (best-candidate-rank best)
                        checked
                        (reverse trace))]
    [else
     (resampling-result 'failed #f #f checked (reverse trace))]))

(define (update-best best candidate rank decision)
  (cond
    [(not best)
     (best-candidate candidate rank (acceptance-decision-score decision))]
    [(> (acceptance-decision-score decision)
        (best-candidate-score best))
     (best-candidate candidate rank (acceptance-decision-score decision))]
    [else best]))

(define (candidate->trace rank candidate decision)
  (candidate-trace "resampling"
                   0
                   rank
                   (number->string (equal-hash-code candidate))
                   (format "~a" candidate)
                   '()
                   0.0
                   (acceptance-decision-score decision)
                   '()
                   (acceptance-decision-constraint-posteriors decision)
                   (acceptance-decision-accepted? decision)
                   (acceptance-decision-diagnostics decision)
                   #f))
