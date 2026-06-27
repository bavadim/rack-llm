#lang racket/base

(require racket/file
         rack-llm/experiments/metrics
         rack-llm/experiments/weak-ifbench/artifacts
         rack-llm/experiments/weak-ifbench/runner
         rack-llm/traces/metadata
         rack-llm/traces/trace)

(define root (build-path "runs" "paper-small"))
(define synthetic-dir (build-path root "synthetic"))
(define weak-dir (build-path root "weak-ifbench"))
(define tables-dir (build-path root "tables"))

(with-handlers ([exn:fail? (lambda (_exn) (void))])
  (delete-directory/files root))

(make-directory* synthetic-dir)
(make-directory* weak-dir)

(define synthetic-records
  (list (eval-record "synthetic-1" 8 1 #t #t (hash 'json #t) 0.95 #t 0.0 1.0 #f #f)
        (eval-record "synthetic-2" 8 #f #f #t (hash 'json #f) 0.25 #f 0.0 1.0 #f #f)))

(call-with-output-file (build-path synthetic-dir "metrics.csv")
  (lambda (out)
    (write-metrics-csv out (summarize-eval-records synthetic-records)))
  #:exists 'replace)

(void
 (run-weak-ifbench
  (runner-config "tests/fixtures/weak-ifbench-six.jsonl"
                 'mock
                 "mock"
                 '(1 2 4 8)
                 42
                 weak-dir)))

(call-with-output-file (build-path weak-dir "traces.jsonl")
  (lambda (out)
    (write-trace-event
     out
     'metadata
     (run-metadata "paper-small"
                   42
                   "0.1.0"
                   #f
                   'mock
                   'exact-full-vocab
                   "mock"
                   #f
                   "weak-ifbench-fixture"
                   "weak-rules"))
    (write-trace-event
     out
     'candidate
     (candidate-trace "paper-small"
                      0
                      1
                      "fixture-candidate"
                      "approved answer"
                      '()
                      0.0
                      0.0
                      '()
                      (hash)
                      #t
                      '()
                      #f)))
  #:exists 'replace)

(generate-artifacts weak-dir tables-dir)

(displayln (path->string root))
