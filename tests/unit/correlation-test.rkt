#lang racket/base

(require rackunit
         rack-llm/rules/acceptance
         rack-llm/rules/correlation)

(define correlation-tests
  (test-suite
   "rule correlation diagnostics"

   (test-case "duplicated rules produce high-agreement warning"
     (define observations
       (list (list (obs 'a 'accept) (obs 'b 'accept))
             (list (obs 'a 'reject) (obs 'b 'reject))
             (list (obs 'a 'accept) (obs 'b 'accept))))
     (define report (analyze-rule-correlations observations))
     (check-= (hash-ref (rule-correlation-report-agreement report) (cons 'a 'b))
              1.0
              1e-9)
     (check-= (hash-ref (rule-correlation-report-conflict report) (cons 'a 'b))
              0.0
              1e-9)
     (check-false (null? (rule-correlation-report-warnings report)))
     (check-equal? (hash-ref (rule-correlation-report->metrics report)
                             'high_correlation_pairs)
                   1))

   (test-case "opposing rules produce conflict matrix entry"
     (define observations
       (list (list (obs 'a 'accept) (obs 'b 'reject))
             (list (obs 'a 'reject) (obs 'b 'accept))))
     (define report (analyze-rule-correlations observations))
     (check-= (hash-ref (rule-correlation-report-agreement report) (cons 'a 'b))
              0.0
              1e-9)
     (check-= (hash-ref (rule-correlation-report-conflict report) (cons 'a 'b))
              1.0
              1e-9)
     (check-false (null? (rule-correlation-report->diagnostics report))))

   (test-case "single shared observation does not warn"
     (define observations
       (list (list (obs 'a 'accept))
             (list (obs 'b 'accept))
             (list (obs 'a 'accept) (obs 'b 'accept))))
     (define report (analyze-rule-correlations observations))
     (check-= (hash-ref (rule-correlation-report-agreement report) (cons 'a 'b))
              1.0
              1e-9)
     (check-equal? (rule-correlation-report-warnings report) '()))

   (test-case "empty and singleton inputs produce empty matrices"
     (define empty-report (analyze-rule-correlations '()))
     (check-equal? (hash-count (rule-correlation-report-agreement empty-report)) 0)
     (define singleton-report
       (analyze-rule-correlations (list (list (obs 'only 'accept)))))
     (check-equal? (hash-count (rule-correlation-report-conflict singleton-report)) 0))))

(define (obs rule-id decision)
  (rule-observation rule-id decision #f (hash)))

(module+ test
  (require rackunit/text-ui)
  (run-tests correlation-tests))
