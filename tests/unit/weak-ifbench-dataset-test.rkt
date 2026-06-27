#lang racket/base

(require racket/runtime-path
         rackunit
         rack-llm/experiments/weak-ifbench/dataset)

(define-runtime-path fixture "../fixtures/weak-ifbench-small.jsonl")

(define weak-ifbench-dataset-tests
  (test-suite
   "Weak-IFBench dataset adapter"

   (test-case "loader reads local JSONL task export"
     (define tasks (load-ifbench-jsonl fixture))
     (check-equal? (length tasks) 2)
     (check-equal? (ifbench-task-id (car tasks)) "task-1")
     (check-equal? (ifbench-task-gold-verifier-id (car tasks)) 'embedded)
     (check-true (constraint-spec? (car (ifbench-task-constraints (car tasks)))))
     (check-equal? (constraint-spec-type
                    (car (ifbench-task-constraints (car tasks))))
                   'phrase-presence))

   (test-case "embedded fake verifier returns prompt and constraint verdicts"
     (define task (car (load-ifbench-jsonl fixture)))
     (define good (run-gold-verifier task "Result: approved"))
     (check-true (gold-verdict-prompt-passed? good))
     (check-true (hash-ref (gold-verdict-constraint-results good) 'phrase))
     (check-true (hash-ref (gold-verdict-constraint-results good) 'format))
     (define bad (run-gold-verifier task "approved only"))
     (check-true (gold-verdict-prompt-passed? bad))
     (check-false (hash-ref (gold-verdict-constraint-results bad) 'format)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests weak-ifbench-dataset-tests))
