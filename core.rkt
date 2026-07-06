#lang racket/base

(provide (struct-out guide)
         (struct-out watch)
         (struct-out ranked)
         (struct-out banned)
         (struct-out generation-result)
         (struct-out check-result)
         found?
         not-found?
         hard-failure?
         low-score?
         provider-error?
         generation-result-ok?
         generation-result-lm-score
         pure
         bind
         ensure-guide
         ensure-watch
         neg-inf
         log-score-add
         log-score-dead?
         log-score>?)

(struct guide (kind data) #:transparent)
(struct watch (kind data) #:transparent)
(struct ranked (score expr) #:transparent)
(struct banned (expr) #:transparent)
(struct generation-result
  (status
   reason
   text
   value
   lm-logprob
   guide-score
   total-score
   hard-ok?
   low-score?
   steps
   attempts
   generated-tokens
   latency-ms
   trace
   metrics)
  #:transparent)
(struct check-result
  (ok? value guide-score hard-ok? trace failures matched-watchers metrics)
  #:transparent)

;; Log-scores use -inf.0 for impossible paths, 0.0 for neutral paths,
;; and finite positive/negative weights for soft preferences.
(define neg-inf -inf.0)

(define (log-score-dead? x)
  (eqv? x neg-inf))

(define (log-score-add a b)
  (if (or (log-score-dead? a) (log-score-dead? b))
      neg-inf
      (+ a b)))

(define (log-score>? a b)
  (> a b))

(define (found? result)
  (eq? (generation-result-status result) 'found))

(define (not-found? result)
  (and (memq (generation-result-status result)
             '(not-found-hard
               not-found-budget
               not-found-low-score
               error-budget
               error-approx-provider
               internal-invalid
               unsupported-guide-for-sampling))
       #t))

(define (hard-failure? result)
  (eq? (generation-result-status result) 'not-found-hard))

(define (low-score? result)
  (eq? (generation-result-status result) 'not-found-low-score))

(define (provider-error? result)
  (eq? (generation-result-status result) 'error-approx-provider))

(define (generation-result-ok? result)
  (found? result))

(define (generation-result-lm-score result)
  (generation-result-lm-logprob result))

(define (pure value)
  (guide 'pure value))

(define (bind g f)
  (unless (guide? g)
    (raise-argument-error 'bind "guide?" g))
  (unless (procedure? f)
    (raise-argument-error 'bind "procedure?" f))
  (guide 'bind (cons g f)))

(define (ensure-guide who v)
  (cond
    [(guide? v) v]
    [(string? v) (guide 'lit v)]
    [(ranked? v) (guide 'ranked-guide (list (ranked-score v) (ranked-expr v)))]
    [else (raise-argument-error who "guide, string, or ranked" v)]))

(define (ensure-watch who v)
  (cond
    [(or (ranked? v) (banned? v) (watch? v)) v]
    [else (raise-argument-error who "rank, ban, or watch" v)]))
