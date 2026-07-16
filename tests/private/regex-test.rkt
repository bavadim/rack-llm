#lang racket/base

(require rackunit
         "../../private/regex.rkt")

(define (run-regex pattern token-texts ids)
  (define machine
    (instantiate-regex-machine (parse-regex-program pattern)
                               (make-regex-vocabulary (list->vector token-texts))))
  (let loop ([state (regex-initial machine)] [remaining ids])
    (cond
      [(null? remaining) state]
      [else
       (define next (regex-step machine state (car remaining)))
       (and next (loop next (cdr remaining)))])))

(define (accepts? pattern token-texts ids)
  (define final-state (run-regex pattern token-texts ids))
  (and final-state
       (regex-accepting?
        (instantiate-regex-machine (parse-regex-program pattern)
                                   (make-regex-vocabulary (list->vector token-texts)))
        final-state)))

(define (terminal? pattern token-texts ids)
  (define machine
    (instantiate-regex-machine (parse-regex-program pattern)
                               (make-regex-vocabulary (list->vector token-texts))))
  (let loop ([state (regex-initial machine)] [remaining ids])
    (cond
      [(null? remaining) (regex-terminal? machine state)]
      [else
       (define next (regex-step machine state (car remaining)))
       (and next (loop next (cdr remaining)))])))

(module+ test
  (test-case "template regex accepts token crossing wildcard and next literal"
    (define pattern "A .{1,5} END")
    (define token-texts '("A " "x E" "ND"))
    (check-true (accepts? pattern token-texts '(0 1 2))))

  (test-case "template regex preserves non-greedy boundary alternatives exactly"
    (define pattern "A .{1,8} END")
    (define token-texts '("A " "x END" " END"))
    (check-true (accepts? pattern token-texts '(0 1 2))))

  (test-case "template regex rejects candidates past bounded wildcard maximum"
    (define pattern "A .{1,2} Z")
    (define token-texts '("A " "abc Z"))
    (check-false (run-regex pattern token-texts '(0 1))))

  (test-case "regex terminal ignores empty tokenizer artifacts"
    (define token-texts '("A " "x" "~END" "" "y"))
    (check-true (terminal? "A [^~]{1,3}~END" token-texts '(0 1 2))))

  (test-case "regex accepting state with real continuations is not terminal"
    (define token-texts '("A " "x" "" "y"))
    (check-false (terminal? "A .{1,3}" token-texts '(0 1))))

  (test-case "regex supports case-insensitive word boundary patterns"
    (define token-texts '("Refund" "prefund" "refunds"))
    (check-true (accepts? "(?i)\\brefund\\b" token-texts '(0)))
    (check-true (accepts? "(?i:\\brefund\\b)" token-texts '(0)))
    (check-false (accepts? "(?i)\\brefund\\b" token-texts '(1)))
    (check-false (accepts? "(?i)\\brefund\\b" token-texts '(2))))

  (test-case "regex supports bounded dotall checks from real soft rules"
    (define token-texts '("hello" "<think>x" "hi"))
    (define pattern "(?is)[\\s\\S]{3,20}")
    (check-true (accepts? pattern token-texts '(0)))
    (check-true (accepts? pattern token-texts '(1)))
    (check-false (accepts? pattern token-texts '(2))))

  (test-case "regex supports multiline structural markers"
    (define token-texts '("- item" "  1) item" "plain item"))
    (define pattern "(?m)^\\s*(?:[-*+]|\\d+[.)])\\s+\\S+")
    (check-true (accepts? pattern token-texts '(0)))
    (check-true (accepts? pattern token-texts '(1)))
    (check-false (accepts? pattern token-texts '(2))))

  (test-case "regex supports Racket pregexp POSIX character classes"
    (define token-texts '("ABC" "abc_123" "abc" "123" "Ж"))
    (check-true (accepts? "[[:alpha:]]+" token-texts '(0)))
    (check-true (accepts? "[[:word:]]+" token-texts '(1)))
    (check-true (accepts? "[^[:digit:]]+" token-texts '(2)))
    (check-false (accepts? "[^[:digit:]]+" token-texts '(3)))
    (check-false (accepts? "[[:alpha:]]+" token-texts '(4))))

  (test-case "regex supports PCRE literal escapes used by experiments"
    (define token-texts '("a\nb" "a\tb" "あ" "A"))
    (check-true (accepts? "a\\nb" token-texts '(0)))
    (check-true (accepts? "a\\tb" token-texts '(1)))
    (check-true (accepts? "[\\u3040-\\u30ff]+" token-texts '(2)))
    (check-true (accepts? "\\u0041" token-texts '(3))))

  (test-case "regex supports lazy quantifier syntax"
    (define token-texts '("aaab" "ab" "b"))
    (check-true (accepts? "a+?b" token-texts '(0)))
    (check-true (accepts? "a{1,3}?b" token-texts '(1)))
    (check-true (accepts? "a??b" token-texts '(2))))

  (test-case "regex supports disabling scoped flags"
    (define token-texts '("Ab" "AB"))
    (check-true (accepts? "(?i:a)(?-i:b)" token-texts '(0)))
    (check-false (accepts? "(?i:a)(?-i:b)" token-texts '(1))))

  (test-case "full-prefix fallback preserves context across token boundaries"
    (for ([item (in-list
                 (list
                  (list "a(?=bc)bc" '("a" "b" "c") '(0 1 2))
                  (list "a(?!bc)b." '("a" "b" "d") '(0 1 2))
                  (list "(?>a|ab)b" '("a" "b") '(0 1))
                  (list "a\\b!" '("a" "!") '(0 1))
                  (list "a\\Bb" '("a" "b") '(0 1))
                  (list "\\R" '("\r" "\n") '(0 1))
                  (list "\\X" '("a" "́") '(0 1))))])
      (check-true
       (accepts? (car item) (cadr item) (caddr item))
       (format "token-split fallback failed for ~s" (car item)))))

  (test-case "restart-safe DFA grows workspace on demand"
    (check-true (accepts? "(?:a?){300}b" '("a" "b") '(0 1))))

  (test-case "shared native vocabulary and states survive collection"
    (define texts
      (for/vector ([id (in-range 100000)])
        (if (= id 99999) " target" (format " filler~a" id))))
    (define vocabulary (make-regex-vocabulary texts))
    (define machines
      (for/list ([i (in-range 12)])
        (instantiate-regex-machine
         (parse-regex-program (if (even? i) " target" " filler99998"))
         vocabulary)))
    (define target-state (regex-initial (car machines)))
    (set! vocabulary #f)
    (collect-garbage)
    (collect-garbage)
    (define final-state (regex-step (car machines) target-state 99999))
    (check-not-false final-state)
    (check-true (regex-accepting? (car machines) final-state))
    (set! target-state #f)
    (collect-garbage)
    (check-true (regex-accepting? (car machines) final-state)))

  (test-case "regex uses PCRE2 syntax and rejects DFA-incompatible constructs"
    (check-exn #rx"unsupported backreference"
               (lambda () (parse-regex-program "(a)\\1")))
    (check-exn #rx"unsupported capture-dependent conditional"
               (lambda () (parse-regex-program "(a)(?(1)b|c)")))
    (check-exn #rx"unsupported PCRE2 DFA construct"
               (lambda () (parse-regex-program "a\\Kb")))
    (check-exn #rx"unsupported PCRE2 DFA construct"
               (lambda () (parse-regex-program "(?R)")))
    (for ([pattern (in-list '("a(?=b)b"
                              "(?<=a)b"
                              "(?>ab|a)b"
                              "[[:punct:]]+"
                              "\\p{L}+"))])
      (check-not-exn (lambda () (parse-regex-program pattern))))))

(module+ test
  (test-case "ERE parser owns end-anchor classification"
    (check-true (ere-pattern-has-end-anchor? (parse-ere-pattern "x$")))
    (check-false (ere-pattern-has-end-anchor? (parse-ere-pattern "x\\$")))
    (check-true (ere-pattern-has-end-anchor? (parse-ere-pattern "x\\\\$")))))
