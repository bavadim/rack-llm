#lang racket/base

(require rackunit
         rack-llm/experiments/complexity)

(define sample-records
  (list (complexity-record "run-1"
                           "ds"
                           8
                           (hash 'expanded_nodes 10.0
                                 'created_edges 30.0
                                 'max_frontier 4.0
                                 'provider_calls 5.0))
        (complexity-record "run-1"
                           "ds"
                           8
                           (hash 'expanded_nodes 14.0
                                 'created_edges 34.0
                                 'max_frontier 6.0
                                 'provider_calls 7.0))
        (complexity-record "run-2"
                           "majority"
                           4
                           (hash 'expanded_nodes 3.0
                                 'created_edges 8.0
                                 'max_frontier 2.0
                                 'provider_calls 2.0))))

(define complexity-tests
  (test-suite
   "complexity metrics table"

   (test-case "aggregate-complexity groups by run method and budget"
     (define aggregate (aggregate-complexity sample-records 'expanded_nodes))
     (define ds (hash-ref aggregate (list "run-1" "ds" 8)))
     (check-equal? (hash-ref ds 'count) 2)
     (check-= (hash-ref ds 'mean) 12.0 1e-9)
     (check-= (hash-ref ds 'std) 2.0 1e-9))

   (test-case "summaries produce stable CSV columns"
     (define summaries (summarize-complexity sample-records))
     (check-equal? (length summaries) 2)
     (check-equal? (complexity-csv-header)
                   "run_id,method,budget,count,expanded_nodes_mean,expanded_nodes_std,created_edges_mean,created_edges_std,agenda_pushes_mean,agenda_pushes_std,agenda_pops_mean,agenda_pops_std,max_frontier_mean,max_frontier_std,provider_calls_mean,provider_calls_std,grammar_checks_mean,grammar_checks_std,yielded_candidates_mean,yielded_candidates_std,queue_time_ms_mean,queue_time_ms_std,provider_time_ms_mean,provider_time_ms_std,rules_time_ms_mean,rules_time_ms_std")
     (define out (open-output-string))
     (write-complexity-csv out summaries)
     (check-true (regexp-match? #rx"run-1,ds,8,2,12.0,2.0"
                                (get-output-string out))))

   (test-case "reader extracts complexity payloads from JSONL traces"
     (define input
       (open-input-string
        (string-append
         "{\"event\":\"metadata\",\"payload\":{\"run_id\":\"ignored\"}}\n"
         "{\"event\":\"complexity\",\"payload\":{\"run_id\":\"r\",\"method\":\"ds\",\"budget\":4,\"expanded_nodes\":5,\"created_edges\":9,\"max_frontier\":3,\"provider_calls\":2,\"grammar_checks\":7,\"queue_time_ms\":1.5,\"provider_time_ms\":2.5,\"rules_time_ms\":0.5}}\n")))
     (define records (read-complexity-records input))
     (check-equal? (length records) 1)
     (check-equal? (complexity-record-run-id (car records)) "r")
     (check-= (hash-ref (complexity-record-metrics (car records))
                        'grammar_checks)
              7.0
              1e-9))))

(module+ test
  (require rackunit/text-ui)
  (run-tests complexity-tests))
