#lang typed/racket/base

(require "rule.rkt"
         "combinators.rkt")

(provide (struct-out rule-observation)
         (struct-out acceptance-input)
         (struct-out acceptance-report)
         run-rules)

(struct rule-observation
  ([rule-id : Symbol]
   [decision : RuleDecision]
   [message : (Option String)]
   [metadata : (HashTable Symbol Any)])
  #:transparent)

(struct acceptance-input
  ([candidate : Any]
   [rules : (Listof weighted-rule)])
  #:transparent)

(struct acceptance-report
  ([hard-passed? : Boolean]
   [observations : (Listof rule-observation)]
   [diagnostics : (Listof String)])
  #:transparent)

(: run-rules (->* (acceptance-input)
                  (#:collect-all-hard-diagnostics? Boolean)
                  acceptance-report))
(define (run-rules input #:collect-all-hard-diagnostics? [collect-all? #t])
  (define candidate (acceptance-input-candidate input))
  (define weighted-rules (acceptance-input-rules input))
  (define observations
    (if collect-all?
        (run-weighted-rules candidate weighted-rules)
        (run-weighted-rules-stop-on-hard-reject candidate weighted-rules)))
  (acceptance-report (hard-passed? weighted-rules observations)
                     observations
                     (observation-diagnostics observations)))

(: run-weighted-rules (-> Any (Listof weighted-rule) (Listof rule-observation)))
(define (run-weighted-rules candidate weighted-rules)
  (map (lambda ([wr : weighted-rule])
         (weighted-rule-observation candidate wr))
       weighted-rules))

(: run-weighted-rules-stop-on-hard-reject
   (-> Any (Listof weighted-rule) (Listof rule-observation)))
(define (run-weighted-rules-stop-on-hard-reject candidate weighted-rules)
  (let loop ([remaining : (Listof weighted-rule) weighted-rules]
             [acc : (Listof rule-observation) '()])
    (cond
      [(null? remaining) (reverse acc)]
      [else
       (define wr (car remaining))
       (define observation (weighted-rule-observation candidate wr))
       (define next (cons observation acc))
       (cond
         [(and (eq? (weighted-rule-kind wr) 'hard)
               (eq? (rule-observation-decision observation) 'reject))
          (reverse next)]
         [else (loop (cdr remaining) next)])])))

(: weighted-rule-observation (-> Any weighted-rule rule-observation))
(define (weighted-rule-observation candidate wr)
  (define r (weighted-rule-rule wr))
  (define result (apply-rule r candidate))
  (rule-observation (rule-id r)
                    (rule-result-decision result)
                    (rule-result-message result)
                    (rule-result-metadata result)))

(: hard-passed? (-> (Listof weighted-rule) (Listof rule-observation) Boolean))
(define (hard-passed? weighted-rules observations)
  (let loop ([rules : (Listof weighted-rule) weighted-rules]
             [obs : (Listof rule-observation) observations])
    (cond
      [(or (null? rules) (null? obs)) #t]
      [(and (eq? (weighted-rule-kind (car rules)) 'hard)
            (eq? (rule-observation-decision (car obs)) 'reject))
       #f]
      [else (loop (cdr rules) (cdr obs))])))

(: observation-diagnostics (-> (Listof rule-observation) (Listof String)))
(define (observation-diagnostics observations)
  (cond
    [(null? observations) '()]
    [else
     (define diagnostic (observation-diagnostic (car observations)))
     (define rest (observation-diagnostics (cdr observations)))
     (if diagnostic
         (cons diagnostic rest)
         rest)]))

(: observation-diagnostic (-> rule-observation (Option String)))
(define (observation-diagnostic observation)
  (define message (rule-observation-message observation))
  (and message
       (format "~a: ~a"
               (rule-observation-rule-id observation)
               message)))
