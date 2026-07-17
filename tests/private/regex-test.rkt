#lang racket/base
(require rackunit "../../private/regex.rkt")
(define (machine pattern pieces)
  (make-hard-regex (parse-ere-pattern pattern)
                   (make-regex-vocabulary (list->vector pieces))))
(define (run m ids)
  (for/fold ([s (regex-start m)]) ([id ids] #:break (not s)) (regex-state-step s id)))
(define (accepts pattern pieces ids)
  (define m (machine pattern pieces)) (define s (run m ids))
  (and s (regex-state-accepting? s)))
(module+ test
  (test-case "tokens may cross regex boundaries"
    (check-true (accepts "A .{1,5} END" '("A " "x E" "ND") '(0 1 2)))
    (check-false (accepts "A .{1,2} Z" '("A " "abc Z") '(0 1))))
  (test-case "allowed token scan follows prefix state"
    (define m (machine "ab(c|x)" '("a" "b" "c" "x" "!")))
    (define at-ab (run m '(0 1)))
    (check-equal? (vector->list (regex-allowed at-ab)) '(2 3)))
  (test-case "bounded and alternate ERE syntax"
    (check-true (accepts "(a|b){1,3}" '("a" "b" "c") '(0 1 0)))
    (check-false (accepts "(a|b){1,3}" '("a" "b" "c") '(0 2))))
  (test-case "absolute anchors agree with complete matching"
    (define m (machine "^[^ \\t\\r\\n]+$" '("a" "\n" "b")))
    (for ([ids '(() (0) (0 1) (0 1 2))])
      (define s (run m ids))
      (define streamed (and s (regex-state-accepting? s)))
      (define text (apply string-append (map (lambda (i) (list-ref '("a" "\n" "b") i)) ids)))
      (check-equal? (and streamed #t) (regex-text-match? m text))))
  (test-case "search matcher is terminal and vocabulary-free"
    (define m (make-text-regex (parse-ere-pattern "a(b)?")))
    (check-true (regex-text-match? m "xxabyy"))
    (check-false (regex-text-match? m "xxyy")))
  (test-case "states retain native owners across collection"
    (define m (machine "target" '("target" "other")))
    (define s (regex-start m))
    (collect-garbage) (define next (regex-state-step s 0))
    (set! s #f) (collect-garbage)
    (check-true (regex-state-accepting? next))))
