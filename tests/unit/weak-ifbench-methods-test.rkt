#lang racket/base

(require rackunit
         rack-llm/experiments/weak-ifbench/dataset
         rack-llm/experiments/weak-ifbench/methods
         rack-llm/rules/threshold-acceptance
         rack-llm/traces/trace)

(define task
  (ifbench-task "task-1"
                "prompt"
                (list (constraint-spec 'phrase
                                       'phrase-presence
                                       (hash 'phrase "approved")))
                'embedded
                (hash 'fake_gold_substring "approved"
                      'fake_constraint_substrings (hash 'phrase "approved"))))

(define ctx
  (experiment-context
   (lambda (_task budget)
     (take-candidates budget
                      (list (candidate 1 "missing phrase" 0.1 (hash))
                            (candidate 2 "approved answer" 0.2 (hash)))))
   #f
   (acceptance-config 'all-constraints 0.5 (hash) (hash))))

(define weak-ifbench-methods-tests
  (test-suite
   "Weak-IFBench baseline methods"

   (test-case "pass1 returns first candidate and forbids larger budgets"
     (define result (run-method 'pass1 ctx task 1))
     (check-equal? (method-result-method result) 'pass1)
     (check-equal? (candidate-rank (method-result-selected result)) 1)
     (check-exn exn:fail? (lambda () (run-method 'pass1 ctx task 8))))

   (test-case "majority baseline selects first threshold-accepted candidate"
     (define result (run-method 'independent-majority ctx task 2))
     (check-equal? (method-result-method result) 'independent-majority)
     (check-equal? (candidate-rank (method-result-selected result)) 2)
     (check-equal? (length (method-result-trace result)) 2))

   (test-case "DS baseline falls back to neutral posteriors without fitted model"
     (define result (run-method 'gumbel-ds ctx task 2))
     (check-equal? (method-result-method result) 'gumbel-ds)
     (check-true (candidate? (method-result-selected result))))

   (test-case "oracle verifier is explicit upper bound"
     (define result (run-method 'oracle-verifier ctx task 2))
     (check-equal? (candidate-rank (method-result-selected result)) 2)
     (check-true
      (regexp-match? #rx"oracle upper bound"
                     (car (candidate-trace-diagnostics
                           (cadr (method-result-trace result)))))))))

(define (take-candidates budget candidates)
  (let loop ([remaining candidates]
             [n budget]
             [acc '()])
    (cond
      [(or (zero? n) (null? remaining)) (reverse acc)]
      [else (loop (cdr remaining) (sub1 n) (cons (car remaining) acc))])))

(module+ test
  (require rackunit/text-ui)
  (run-tests weak-ifbench-methods-tests))
