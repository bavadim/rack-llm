#lang racket/base

(require rackunit
         rack-llm/grammar/combinators
         rack-llm/rules/combinators)

(define combinator-boundary-tests
  (test-suite
   "grammar/rule combinator boundary"

   (test-case "grammar and rule combinator modules expose distinct names"
     (check-true (procedure? one-or-more))
     (check-true (procedure? rule-at-least)))

   (test-case "no public at_least_ones compatibility alias exists"
     (define-values (_values syntax-exports)
       (module->exports 'rack-llm/grammar/combinators))
     (define exported
       (for/list ([phase-group (in-list syntax-exports)]
                  #:when (equal? (car phase-group) 0)
                  [binding (in-list (cdr phase-group))])
         (car binding)))
     (check-false (member 'at_least_ones exported)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests combinator-boundary-tests))
