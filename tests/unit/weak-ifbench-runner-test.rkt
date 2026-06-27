#lang racket/base

(require json
         racket/file
         racket/port
         racket/runtime-path
         rackunit
         rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/runner)

(define-runtime-path fixture "../fixtures/weak-ifbench-six.jsonl")

(define weak-ifbench-runner-tests
  (test-suite
   "Weak-IFBench split runner"

   (test-case "make-split is deterministic and disjoint"
     (define tasks (load-ifbench-jsonl fixture))
     (define s1 (make-split tasks 42))
     (define s2 (make-split tasks 42))
     (check-equal? s1 s2)
     (check-equal? (length (experiment-split-calibration s1)) 2)
     (check-equal? (length (experiment-split-dev s1)) 2)
     (check-equal? (length (experiment-split-test s1)) 2)
     (check-true (disjoint? (experiment-split-calibration s1)
                            (experiment-split-test s1)))
     (check-true (disjoint? (experiment-split-dev s1)
                            (experiment-split-test s1))))

   (test-case "fixture runner writes split model threshold and metrics outputs"
     (define out-dir (make-temporary-file "weak-ifbench-run-~a" 'directory))
     (dynamic-wind
      (lambda () (void))
      (lambda ()
        (define split
          (run-weak-ifbench
           (runner-config fixture 'mock "mock" '(1 2) 42 out-dir)))
        (check-true (experiment-split? split))
        (check-true (directory-exists? (build-path out-dir "calibration")))
        (check-true (directory-exists? (build-path out-dir "dev")))
        (check-true (directory-exists? (build-path out-dir "test")))
        (check-true (directory-exists? (build-path out-dir "models")))
        (check-true (file-exists? (build-path out-dir "models" "ds-model.json")))
        (check-true (file-exists? (build-path out-dir "models" "thresholds.json")))
        (check-true (file-exists? (build-path out-dir "experiment-config.json")))
        (check-true (file-exists? (build-path out-dir "metrics.csv")))
        (define split-js
          (call-with-input-file (build-path out-dir "split.json") read-json))
        (check-equal? (length (hash-ref split-js 'calibration)) 2)
        (define config-js
          (call-with-input-file (build-path out-dir "experiment-config.json") read-json))
        (define run-js
          (call-with-input-file (build-path out-dir "run.json") read-json))
        (check-equal? (hash-ref run-js 'config_hash)
                      (hash-ref config-js 'config_hash))
        (define metrics-text
          (call-with-input-file (build-path out-dir "metrics.csv") port->string))
        (check-true (regexp-match? #rx"^config_hash," metrics-text)))
      (lambda ()
        (delete-directory/files out-dir))))

   (test-case "parse-budgets accepts comma separated positive integers"
     (check-equal? (parse-budgets "1,2,4,8") '(1 2 4 8))
     (check-exn exn:fail? (lambda () (parse-budgets "1,0"))))))

(define (disjoint? left right)
  (not (for/or ([item (in-list left)])
         (member item right))))

(module+ test
  (require rackunit/text-ui)
  (run-tests weak-ifbench-runner-tests))
