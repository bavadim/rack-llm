#lang racket/base

(require racket/file
         racket/runtime-path
         rackunit
         rack-llm/experiments/weak-ifbench/artifacts
         rack-llm/experiments/weak-ifbench/runner)

(define-runtime-path fixture "../fixtures/weak-ifbench-six.jsonl")

(define weak-ifbench-artifacts-tests
  (test-suite
   "Weak-IFBench paper artifacts"

   (test-case "fixture run produces paper CSV and Markdown artifacts"
     (define run-dir (make-temporary-file "weak-ifbench-run-~a" 'directory))
     (define table-dir (make-temporary-file "weak-ifbench-tables-~a" 'directory))
     (dynamic-wind
      (lambda () (void))
      (lambda ()
        (run-weak-ifbench
         (runner-config fixture 'mock "mock" '(1 2 4 8) 42 run-dir))
        (generate-artifacts run-dir table-dir)
        (check-true (file-exists? (build-path table-dir "main_results.csv")))
        (check-true (file-exists? (build-path table-dir "calibration_metrics.csv")))
        (check-true (file-exists? (build-path table-dir "cost_metrics.csv")))
        (check-true (file-exists? (build-path table-dir "ablation_results.csv")))
        (check-true (file-exists? (build-path table-dir "summary.md")))
        (check-true (csv-has-column? (build-path table-dir "main_results.csv")
                                     "GoldSuccess@8"))
        (check-true (csv-has-column? (build-path table-dir "calibration_metrics.csv")
                                     "Brier")))
      (lambda ()
        (delete-directory/files run-dir)
        (delete-directory/files table-dir))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests weak-ifbench-artifacts-tests))
