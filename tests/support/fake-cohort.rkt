#lang racket/base

(require "../../private/domain.rkt"
         "../../private/model.rkt"
         "logits.rkt" "reference-sampling.rkt"
         racket/list)

(provide make-fake-cohort-provider)

;; Test backend with the same fixed-cohort contract as the native provider.
;; Each lane owns an independent session value; every decode advances all lanes.
(define (make-fake-cohort-provider
         #:vocab-size vocab-size
         #:eog-token-ids eog-token-ids
         #:cohort-width [width 4]
         #:start-lane start
         #:logits/lane logits
         #:commit-lane! commit
         #:close-lane! [close (lambda (_session) (void))]
         #:on-restore [on-restore (lambda (_lanes) (void))]
         #:on-decode-width [on-width (lambda (_width) (void))])
  (define (open prompts)
    (vector prompts (list->vector (map start prompts)) (box #t)))
  (define (sessions cohort) (vector-ref cohort 1))
  (define (ensure-open who cohort)
    (unless (unbox (vector-ref cohort 2)) (error who "closed fake cohort")))
  (provider
   #:vocab-size vocab-size
   #:eog-token-ids eog-token-ids
   #:cohort-width width
   #:open-cohort open
   #:restore-lanes!
   (lambda (cohort lanes)
     (ensure-open 'fake-restore cohort)
     (on-restore lanes)
     (for ([lane (in-list lanes)])
       (close (vector-ref (sessions cohort) lane))
       (vector-set! (sessions cohort) lane
                    (start (list-ref (vector-ref cohort 0) lane)))))
   #:sample-factors
   (lambda (cohort entries)
     (ensure-open 'fake-factor cohort)
     (for/list ([entry (in-list entries)])
       (define lane (car entry))
       (define request (cdr entry))
       (define domain (factor-request-domain request))
       (define children (factor-request-children request))
       (define child-table (make-hash children))
       (define constrain? (factor-request-constrain? request))
       (sample-factor-logits
        (logits (vector-ref (sessions cohort) lane)) (factor-request-draw request)
        (factor-request-temperature request)
        (lambda (id)
          (cond [(and constrain? (not (domain-member? domain id))) -inf.0]
                [else
                 (define mass (hash-ref child-table id 1.0))
                 (if (<= mass 0.0) -inf.0 (log mass))]))
        (lambda (id) (domain-member? domain id)))))
   #:decode!
   (lambda (cohort tokens)
     (ensure-open 'fake-decode cohort)
     (on-width (length tokens))
     (for ([session (in-vector (sessions cohort))] [token (in-list tokens)])
       (commit session token)))
   #:close-cohort!
   (lambda (cohort _poisoned?)
     (when (unbox (vector-ref cohort 2))
       (for ([session (in-vector (sessions cohort))]) (close session))
       (set-box! (vector-ref cohort 2) #f)))))
