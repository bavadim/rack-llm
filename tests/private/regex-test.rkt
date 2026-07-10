#lang racket/base

(require rackunit
         "../../private/regex.rkt")

(define (run-regex pattern token-texts ids)
  (define machine
    (instantiate-regex-machine (parse-regex-program pattern)
                               (list->vector token-texts)))
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
                                   (list->vector token-texts))
        final-state)))

(define (terminal? pattern token-texts ids)
  (define machine
    (instantiate-regex-machine (parse-regex-program pattern)
                               (list->vector token-texts)))
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
    (check-false (terminal? "A .{1,3}" token-texts '(0 1)))))
