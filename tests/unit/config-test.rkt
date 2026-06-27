#lang racket/base

(require json
         racket/file
         rackunit
         rack-llm/experiments/config)

(define cfg
  (experiment-config 'mock
                     "model"
                     "prompt"
                     "grammar"
                     '("rule/a" "rule/b")
                     '(1 2 4)
                     42
                     (hash 'calibration '("a") 'dev '("b") 'test '("c"))
                     (hash 'data "fixture.jsonl")))

(define config-tests
  (test-suite
   "experiment config freeze"

   (test-case "config hash is deterministic and content-sensitive"
     (check-equal? (experiment-config-hash cfg) (experiment-config-hash cfg))
     (define cfg2
       (experiment-config 'mock
                          "model"
                          "prompt"
                          "grammar"
                          '("rule/a" "rule/b")
                          '(1 2 8)
                          42
                          (hash 'calibration '("a") 'dev '("b") 'test '("c"))
                          (hash 'data "fixture.jsonl")))
     (check-not-equal? (experiment-config-hash cfg)
                       (experiment-config-hash cfg2)))

   (test-case "write-experiment-config embeds config hash"
     (define out (make-temporary-file "experiment-config-~a.json"))
     (dynamic-wind
      (lambda () (void))
      (lambda ()
        (write-experiment-config cfg out)
        (define js (call-with-input-file out read-json))
        (check-equal? (hash-ref js 'config_hash)
                      (experiment-config-hash cfg)))
      (lambda ()
        (delete-file out))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests config-tests))
