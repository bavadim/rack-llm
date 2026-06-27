#lang racket/base

(require rackunit
         rack-llm/rules/acceptance
         rack-llm/rules/aggregation-baselines
         rack-llm/rules/dawid-skene
         rack-llm/rules/threshold-acceptance)

(define aggregation-baseline-tests
  (test-suite
   "aggregation baselines"

   (test-case "majority baseline returns posterior-like score"
     (check-= (majority-posterior-like
               (list (obs 'a 'accept) (obs 'b 'accept) (obs 'c 'reject)))
              1.0
              1e-9)
     (check-= (majority-posterior-like
               (list (obs 'a 'accept) (obs 'b 'reject) (obs 'c 'abstain)))
              0.5
              1e-9)
     (check-= (majority-posterior-like
               (list (obs 'a 'reject) (obs 'b 'abstain)))
              0.0
              1e-9))

   (test-case "equal-weight baseline ignores abstentions"
     (check-= (equal-weight-score
               (list (obs 'a 'accept) (obs 'b 'accept) (obs 'c 'reject)))
              (/ 2.0 3.0)
              1e-9)
     (check-= (equal-weight-score
               (list (obs 'a 'accept) (obs 'b 'reject) (obs 'c 'abstain)))
              0.5
              1e-9)
     (check-= (equal-weight-score
               (list (obs 'a 'abstain) (obs 'b 'abstain)))
              0.5
              1e-9))

   (test-case "baselines produce per-constraint posteriors for acceptance"
     (define observations
       (list (constraint-observation 'format (obs 'json 'accept))
             (constraint-observation 'format (obs 'schema 'accept))
             (constraint-observation 'length (obs 'word-count 'reject))
             (constraint-observation 'length (obs 'sentence-count 'accept))))
     (define majority (baseline-constraint-posteriors 'majority observations))
     (define equal-weight (baseline-constraint-posteriors 'equal-weight observations))
     (check-= (hash-ref majority 'format) 1.0 1e-9)
     (check-= (hash-ref majority 'length) 0.5 1e-9)
     (check-= (hash-ref equal-weight 'format) 1.0 1e-9)
     (check-= (hash-ref equal-weight 'length) 0.5 1e-9)
     (define decision
       (accept-posteriors (acceptance-config 'all-constraints
                                             0.5
                                             (hash)
                                             (hash))
                          (acceptance-report #t '() '())
                          equal-weight))
     (check-true (acceptance-decision-accepted? decision)))))

(define (obs rule-id decision)
  (rule-observation rule-id decision #f (hash)))

(module+ test
  (require rackunit/text-ui)
  (run-tests aggregation-baseline-tests))
