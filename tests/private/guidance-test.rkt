#lang racket/base
(require rackunit "../../main.rkt" "../../backend.rkt")
(define pieces #( "a" "b" "x" "!" "\n"))
(define (encode s)
  (for/list ([ch (in-string s)])
    (or (for/first ([p (in-vector pieces)] [i (in-naturals)] #:when (string=? p (string ch))) i)
        (error 'encode "unknown character"))))
(define tok (make-tokenizer #:vocab-size 5 #:fingerprint "guidance-test-v1"
                            #:token-ref (lambda (i) (vector-ref pieces i))
                            #:tokenize encode
                            #:detokenize (lambda (ids) (apply string-append (map (lambda (i) (vector-ref pieces i)) ids)))))
(define provider
  (make-provider #:vocab-size 5 #:eog-token-ids '(4) #:cohort-width 1
                 #:open-cohort void #:restore-lanes! void #:sample-factors void
                 #:decode! void #:close-cohort! void))
(define model (make-backend tok provider void))
(define (compile p) (compile-spec model p))
(module+ test
  (test-case "text accepts through bound"
    (define p (compile (text 2)))
    (for ([s '("" "a" "ab")]) (check-true (accepts? p s)))
    (check-false (accepts? p "abx")))
  (test-case "sequence keeps short and long alternatives"
    (define p (compile (seq (choice (lit "a") (lit "ab")) (lit "x"))))
    (check-true (accepts? p "ax")) (check-true (accepts? p "abx"))
    (check-false (accepts? p "ab")))
  (test-case "nullable regex keeps continuation"
    (define p (compile (seq (ere "a(b)?") (lit "x"))))
    (check-true (accepts? p "ax")) (check-true (accepts? p "abx")))
  (test-case "repeat preserves ambiguous parses"
    (define p (compile (repeat 1 2 (choice (lit "a") (lit "ab")))))
    (for ([s '("a" "ab" "aa" "aab" "aba" "abab")]) (check-true (accepts? p s) s)))
  (test-case "nested weak scopes use structural slots and OR over parses"
    (define p
      (compile
       (repeat 1 2
               (choice (with-rules (lit "a") (positive (lit "a")))
                       (with-rules (lit "aa") (negative (lit "aa")))))))
    (check-equal? (observe-token-ids p (encode "aa")) #(1 -1)))
  (test-case "weak rules are scoped"
    (define p
      (compile (seq (with-rules (choice (lit "a") (lit "ab"))
                                (positive (ere "b$")) (negative (lit "x")))
                    (lit "x"))))
    (check-equal? (observe-token-ids p (encode "abx")) #(1 0))
    (check-equal? (observe-token-ids p (encode "ax")) #(0 0)))
  (test-case "invalid layouts fail at compile"
    (check-exn #rx"tail position" (lambda () (compile (seq (text 2) (lit "x")))))
    (check-exn #rx"text cannot be repeated" (lambda () (compile (repeat 1 2 (text 2)))))
    (check-exn #rx"must consume" (lambda () (compile (repeat 1 2 (lit ""))))))
  (test-case "whole-text anchors are strict"
    (define p (compile (ere "^a$")))
    (check-true (accepts? p "a")) (check-false (accepts? p "a\n"))))
