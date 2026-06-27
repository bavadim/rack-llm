#lang racket/base

(require rackunit
         rack-llm/grammar
         rack-llm/grammar/combinators
         rack-llm/grammar/diagnostics
         rack-llm/grammar/json
         rack-llm/grammar/mask)

(define (advance-all matcher pieces)
  (foldl (lambda (piece state)
           (matcher-advance matcher state piece))
         (matcher-start matcher)
         pieces))

(define (softmax-sum logits)
  (for/sum ([logit (in-vector logits)]
            #:unless (eqv? logit -inf.0))
    (exp logit)))

(define grammar-combinator-tests
  (test-suite
   "grammar combinators, matcher, json helpers, masks, diagnostics"

   (test-case "seq and optional enumerate finite strings"
     (define g (seq (lit "a") (optional (lit "b")) (lit "c")))
     (check-equal? (grammar->strings g #:max-depth 4) '("ac" "abc"))
     (check-true (grammar-accepts? g "ac"))
     (check-true (grammar-accepts? g "abc"))
     (check-false (grammar-accepts? g "abbc")))

   (test-case "sep-by with regex enforces bounds"
     (define g (sep-by (regex "[0-9]") (lit ",") 1 3))
     (check-true (grammar-accepts? g "1"))
     (check-true (grammar-accepts? g "1,2,3"))
     (check-false (grammar-accepts? g "1,2,3,4")))

   (test-case "incremental matcher advances token strings and records captures"
     (define m
       (compile-matcher
        (seq (lit "a")
             (choice (lit "b") (list (lit "c"))))))
     (define s1 (matcher-advance m (matcher-start m) "a"))
     (check-true (matcher-viable? s1))
     (check-false (matcher-accepting? s1))
     (check-true (matcher-accepting? (matcher-advance m s1 "b")))
     (check-false (matcher-viable? (matcher-advance m s1 "x")))

     (define cm (compile-matcher (capture 'name (regex "[a-z]+"))))
     (define cs (advance-all cm '("a" "b")))
     (check-true (matcher-accepting? cs))
     (check-equal? (hash-ref (matcher-captures cs) 'name) "ab"))

   (test-case "allowed token masks and logit normalization"
     (define vocab '#("a" "b" "c"))
     (define m (compile-matcher (choice (lit "a") (list (lit "b")))))
     (define mask (allowed-token-mask m (matcher-start m) vocab))
     (check-equal? (vector->list mask) '(#t #t #f))
     (define q (normalize-masked-logits (mask-logits '#(0.0 0.0 0.0) mask)))
     (check-equal? (vector-ref q 2) -inf.0)
     (check-= (softmax-sum q) 1.0 1e-8))

   (test-case "ordered json helpers accept required and optional fields"
     (define g
       (json-object
        (list (json-field "status" (json-enum '("ok" "error")) #t)
              (json-field "retry" json-boolean #t)
              (json-field "note" (json-string #:max-chars 4) #f))))
     (check-true (grammar-accepts? g "{\"status\":\"ok\",\"retry\":true}"))
     (check-true (grammar-accepts? g "{\"status\":\"error\",\"retry\":false,\"note\":\"A1\"}"))
     (check-false (grammar-accepts? g "{\"status\":\"wat\",\"retry\":true}")))

   (test-case "compile diagnostics cover common grammar mistakes"
     (define empty-choice (compile-grammar/check (choice)))
     (check-true (list? empty-choice))
     (check-equal? (grammar-diagnostic-code (car empty-choice)) 'empty-choice)

     (define impossible (compile-grammar/check (repeat (lit "x") 3 2)))
     (check-equal? (grammar-diagnostic-code (car impossible)) 'impossible-repeat)

     (define duplicate
       (compile-grammar/check
        (seq (capture 'x (lit "a")) (capture 'x (lit "b")))))
     (check-equal? (grammar-diagnostic-code (car duplicate)) 'duplicate-capture)

     (define unsupported (compile-grammar/check (regex "(?<=a)b")))
     (check-equal? (grammar-diagnostic-code (car unsupported)) 'unsupported-regex))))

(module+ test
  (require rackunit/text-ui)
  (run-tests grammar-combinator-tests))
