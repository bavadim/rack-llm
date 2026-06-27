#lang racket/base

(require json
         rackunit
         rack-llm/experiments/metrics)

(define records
  (list (eval-record "a" 4 1 #t #t (hash 'format #t 'length #f) 0.9 #t 0.0 10.0 2 0.10)
        (eval-record "b" 4 #f #f #t (hash 'format #f 'length #f) 0.2 #f 0.5 20.0 2 0.20)
        (eval-record "c" 4 2 #t #t (hash 'format #t) 0.8 #t 0.25 30.0 2 0.30)
        (eval-record "d" 4 #f #f #f (hash 'length #t) 0.1 #f 0.25 40.0 2 0.40)))

(define perfect-records
  (list (eval-record "p1" 2 1 #t #t (hash 'c #t) 1.0 #t 0.0 1.0 #f #f)
        (eval-record "p2" 2 #f #f #t (hash 'c #f) 0.0 #f 0.0 1.0 #f #f)))

(define metrics-tests
  (test-suite
   "selection and calibration metrics"

   (test-case "prompt-level rates and efficiency are means"
     (check-= (gold-success-at-b records) 0.5 1e-9)
     (check-= (oracle-at-b records) 0.75 1e-9)
     (check-= (selection-efficiency-at-b records) (/ 0.5 0.75) 1e-9))

   (test-case "constraint-level success aggregates globally and by id"
     (check-= (constraint-success-at-b records) (/ 3.0 6.0) 1e-9)
     (define by-id (constraint-success-by-id records))
     (check-= (hash-ref by-id 'format) (/ 2.0 3.0) 1e-9)
     (check-= (hash-ref by-id 'length) (/ 1.0 3.0) 1e-9))

   (test-case "calibration metrics handle perfect predictions"
     (check-= (brier-score perfect-records) 0.0 1e-9)
     (check-= (ece-score perfect-records 2) 0.0 1e-9)
     (check-= (auroc-score perfect-records) 1.0 1e-9))

   (test-case "auroc uses half credit for ties"
     (define tied
       (list (eval-record "p" 1 1 #t #t (hash) 0.5 #t 0.0 1.0 #f #f)
             (eval-record "n" 1 #f #f #t (hash) 0.5 #f 0.0 1.0 #f #f)))
     (check-= (auroc-score tied) 0.5 1e-9))

   (test-case "zero oracle efficiency is NaN in API and null in JSON"
     (define no-oracle
       (list (eval-record "x" 1 #f #f #f (hash) 0.2 #f 0.0 1.0 #f #f)))
     (define efficiency (selection-efficiency-at-b no-oracle))
     (check-true (not (= efficiency efficiency)))
     (define js (metrics->json (summarize-eval-records no-oracle)))
     (check-equal? (hash-ref js 'selection_efficiency_at_b) 'null))

   (test-case "summary and output helpers have stable scalar fields"
     (define summary (summarize-eval-records records #:ece-bins 5))
     (check-equal? (hash-ref summary 'record_count) 4)
     (check-= (hash-ref summary 'duplicate_rate) 0.25 1e-9)
     (check-= (hash-ref summary 'avg_candidates) 4.0 1e-9)
     (check-= (hash-ref summary 'latency_ms) 25.0 1e-9)
     (check-= (hash-ref summary 'provider_k) 2.0 1e-9)
     (check-= (hash-ref summary 'truncated_mass_mean) 0.25 1e-9)
     (check-equal? (metrics-csv-header)
                   "record_count,gold_success_at_b,oracle_at_b,selection_efficiency_at_b,constraint_success_at_b,brier,ece,auroc,duplicate_rate,avg_candidates,latency_ms,provider_k,truncated_mass_mean")
     (define csv-out (open-output-string))
     (write-metrics-csv csv-out summary)
     (check-true (regexp-match? #rx"^record_count,gold_success_at_b"
                                (get-output-string csv-out)))
     (define json-out (open-output-string))
     (write-metrics-json json-out summary)
     (check-true (hash? (string->jsexpr (get-output-string json-out)))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests metrics-tests))
