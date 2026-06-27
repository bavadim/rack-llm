#lang racket/base

(require json
         rackunit
         rack-llm/rules/acceptance
         rack-llm/sampling/sampler-stats
         rack-llm/traces/metadata
         rack-llm/traces/reader
         rack-llm/traces/trace)

(define metadata-tests
  (test-suite
   "run metadata"

   (test-case "metadata serializes to JSON-compatible hash"
     (define m
       (run-metadata "r1" 42 "0.1" #f 'mock 'exact "mock" #f "g1" "h1"))
     (define js (run-metadata->json m))
     (check-equal? (hash-ref js 'seed) 42)
     (check-equal? (hash-ref js 'provider_mode) "exact")
     (check-equal? (hash-ref js 'git_commit) 'null))

   (test-case "metadata records release provider modes"
     (for ([mode (in-list '(exact truncated compat))])
       (define js
         (run-metadata->json
          (run-metadata "r1" 1 "0.1" #f 'mock mode "mock" #f "g" "r")))
       (check-equal? (hash-ref js 'provider_mode) (symbol->string mode))))

   (test-case "candidate trace serializes schema version and redaction"
     (define trace
       (candidate-trace "r1"
                        0
                        1
                        "abc"
                        "secret"
                        '(1 2)
                        -1.5
                        0.25
                        (list (rule-observation 'json-valid 'accept #f (hash)))
                        (hash 'json 0.9)
                        #t
                        '()
                        #f))
     (define js (candidate-trace->json trace))
     (check-equal? (hash-ref js 'schema_version) "1")
     (check-equal? (hash-ref js 'accepted) #t)
     (check-equal? (hash-ref js 'text) "secret")
     (check-equal? (hash-ref (candidate-trace->json trace #:redact-text? #t) 'text)
                   'null))

   (test-case "candidate trace flattens sampler stats for complexity tables"
     (define trace
       (candidate-trace "r1"
                        0
                        1
                        "abc"
                        "secret"
                        '(1 2)
                        -1.5
                        0.25
                        '()
                        (hash)
                        #t
                        '()
                        (sampler-stats 2 3 4 5 6 7 8 1)))
     (define js (candidate-trace->json trace))
     (check-equal? (hash-ref js 'expanded_nodes) 2)
     (check-equal? (hash-ref js 'agenda_pushes) 4)
     (check-equal? (hash-ref (hash-ref js 'sampler_stats) 'yielded_candidates) 1))

   (test-case "trace events write one JSON object per line"
     (define out (open-output-string))
     (write-trace-event out
                        'metadata
                        (run-metadata "r1" 42 "0.1" #f 'mock 'exact "mock" #f "g1" "h1"))
     (define line (get-output-string out))
     (define event (string->jsexpr line))
     (check-equal? (hash-ref event 'schema_version) "1")
     (check-equal? (hash-ref event 'event) "metadata")
     (check-equal? (hash-ref (hash-ref event 'payload) 'run_id) "r1"))

   (test-case "trace reader reconstructs selected candidate rank"
     (define out (open-output-string))
     (write-trace-event out
                        'candidate
                        (candidate-trace "r1" 0 1 "h1" "no" '(1) -2.0 0.1 '() (hash) #f '() #f))
     (write-trace-event out
                        'candidate
                        (candidate-trace "r1" 0 2 "h2" "yes" '(2) -1.0 0.2 '() (hash) #t '() #f))
     (define events
       (read-trace-events (open-input-string (get-output-string out))))
     (check-equal? (length events) 2)
     (check-equal? (selected-candidate-rank events) 2))))

(module+ test
  (require rackunit/text-ui)
  (run-tests metadata-tests))
