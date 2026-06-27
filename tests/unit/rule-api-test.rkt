#lang racket/base

(require rackunit
         rack-llm/rules/rule
         rack-llm/rules/combinators
         rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene
         rack-llm/rules/threshold-acceptance)

(define rule-api-tests
  (test-suite
   "rule API"

   (test-case "apply-rule returns accept and reject decisions as data"
     (define r
       (rule 'non-empty
             "reject empty strings"
             'candidate
             (lambda (x)
               (if (and (string? x) (not (string=? x "")))
                   (accept)
                   (reject #:message "empty")))))
     (check-equal? (rule-result-decision (apply-rule r "x")) 'accept)
     (define rejected (apply-rule r ""))
     (check-equal? (rule-result-decision rejected) 'reject)
     (check-equal? (rule-result-message rejected) "empty"))

   (test-case "all three rule decisions are constructible"
     (check-equal? (rule-result-decision (accept)) 'accept)
     (check-equal? (rule-result-decision (reject)) 'reject)
     (check-equal? (rule-result-decision (abstain)) 'abstain))

   (test-case "rule-at-least aggregates rule decisions without stdout diagnostics"
     (define yes (rule 'yes "always accept" 'candidate (lambda (_x) (accept))))
     (define no (rule 'no "always reject" 'candidate (lambda (_x) (reject))))
     (define agg (rule-at-least 2 (list yes yes no)))
     (define result (apply-rule agg "candidate"))
     (check-equal? (rule-result-decision result) 'accept)
     (check-equal? (hash-ref (rule-result-metadata result) 'accepts) 2))

   (test-case "rule combinators implement boolean-style aggregation"
     (define yes (rule 'yes "always accept" 'candidate (lambda (_x) (accept))))
     (define no (rule 'no "always reject" 'candidate (lambda (_x) (reject))))
     (define maybe (rule 'maybe "always abstain" 'candidate (lambda (_x) (abstain))))
     (check-equal? (rule-result-decision (apply-rule (all-of 'all "" (list yes no)) 'x)) 'reject)
     (check-equal? (rule-result-decision (apply-rule (at-least 'two "" 2 (list yes yes no)) 'x)) 'accept)
     (check-equal? (rule-result-decision (apply-rule (any-of 'any "" (list maybe no)) 'x)) 'abstain)
     (check-equal? (rule-result-decision (apply-rule (exactly 'one "" 1 (list yes no)) 'x)) 'accept)
     (check-equal? (rule-result-decision (apply-rule (none-of 'none "" (list no no)) 'x)) 'accept)
     (check-equal? (rule-result-decision (apply-rule (implies 'imp "" yes no) 'x)) 'reject)
     (define metadata (rule-result-metadata (apply-rule (all-of 'all "" (list yes no)) 'x)))
     (check-equal? (map (lambda (child) (hash-ref child 'rule-id))
                        (hash-ref metadata 'children))
                   '(yes no)))

   (test-case "hard and soft wrappers preserve explicit kind and weight"
     (define yes (rule 'yes "always accept" 'candidate (lambda (_x) (accept))))
     (check-equal? (weighted-rule-kind (hard yes)) 'hard)
     (check-equal? (weighted-rule-kind (soft yes #:weight 0.25)) 'soft)
     (check-equal? (weighted-rule-weight (soft yes #:weight 0.25)) 0.25))

   (test-case "acceptance engine collects hard and soft observations"
     (define json-rule
       (rule 'json-valid "reject invalid json" 'candidate
             (lambda (_x) (reject #:message "invalid json"))))
     (define style-rule
       (rule 'style "style weak rule" 'candidate
             (lambda (_x) (accept #:metadata (hash 'score 1.0)))))
     (define report
       (run-rules (acceptance-input "bad-json"
                                    (list (hard json-rule)
                                          (soft style-rule)))))
     (check-false (acceptance-report-hard-passed? report))
     (check-equal? (map rule-observation-rule-id
                        (acceptance-report-observations report))
                   '(json-valid style))
     (check-equal? (acceptance-report-diagnostics report)
                   '("json-valid: invalid json")))

   (test-case "thresholded acceptance accepts when all constraints pass"
     (define report (acceptance-report #t '() '()))
     (define model (static-per-constraint-model (hash 'word-count 0.9
                                                      'phrase 0.8)))
     (define cfg (acceptance-config 'all-constraints 0.7 (hash) (hash)))
     (define d (accept-candidate cfg report model
                                 (list (constraint-observation 'word-count
                                                               (rule-observation 'r 'accept #f (hash)))
                                       (constraint-observation 'phrase
                                                               (rule-observation 'r 'accept #f (hash))))))
     (check-true (acceptance-decision-accepted? d))
     (check-true (hash? (acceptance-decision-constraint-posteriors d)))
     (check-equal? (acceptance-decision-score d) 0.8))

   (test-case "thresholded acceptance rejects with human-readable reason"
     (define report (acceptance-report #t '() '()))
     (define model (static-per-constraint-model (hash 'word-count 0.4
                                                      'phrase 0.9)))
     (define cfg (acceptance-config 'all-constraints
                                    0.7
                                    (hash 'word-count 0.6)
                                    (hash)))
     (define d (accept-candidate cfg report model
                                 (list (constraint-observation 'word-count
                                                               (rule-observation 'r 'accept #f (hash)))
                                       (constraint-observation 'phrase
                                                               (rule-observation 'r 'accept #f (hash))))))
     (check-false (acceptance-decision-accepted? d))
     (check-not-false (member "constraint word-count below threshold"
                              (acceptance-decision-diagnostics d))))

   (test-case "thresholded acceptance supports weighted and min-posterior modes"
     (define report (acceptance-report #t '() '()))
     (define model (static-per-constraint-model (hash 'a 0.2 'b 0.9)))
     (define observations
       (list (constraint-observation 'a (rule-observation 'r 'accept #f (hash)))
             (constraint-observation 'b (rule-observation 'r 'accept #f (hash)))))
     (define weighted
       (accept-candidate (acceptance-config 'weighted-sum 0.7 (hash) (hash 'a 1.0 'b 3.0))
                         report
                         model
                         observations))
     (check-true (acceptance-decision-accepted? weighted))
     (check-= (acceptance-decision-score weighted) 0.725 1e-9)
     (define min-d
       (accept-candidate (acceptance-config 'min-posterior 0.5 (hash) (hash))
                         report
                         model
                         observations))
     (check-false (acceptance-decision-accepted? min-d))
     (check-not-false (member "minimum constraint posterior below threshold"
                              (acceptance-decision-diagnostics min-d)))) ))

(define (static-per-constraint-model posterior-table)
  (per-constraint-ds-model
   (for/hash ([(constraint-id posterior) (in-hash posterior-table)])
     (values constraint-id (static-ds-model posterior)))
   #f))

(define (static-ds-model posterior)
  (define p (max 1e-6 (min (- 1.0 1e-6) posterior)))
  (ds-model '(r)
            0.5
            (hash 'r (hash 0 (hash 'accept (- 1.0 p)
                                   'reject p
                                   'abstain 1e-6)
                           1 (hash 'accept p
                                   'reject (- 1.0 p)
                                   'abstain 1e-6)))
            0
            #t
            (ds-orientation 'manual #f 1)))

(module+ test
  (require rackunit/text-ui)
  (run-tests rule-api-tests))
