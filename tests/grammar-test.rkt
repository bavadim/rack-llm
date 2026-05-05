#lang racket/base

(require rackunit
         rack-llm)

(define (make-sequence-model outputs)
  (define remaining (box outputs))
  (make-chat-model
   (lambda (req)
     (define xs (unbox remaining))
     (cond
       [(null? xs) "fallback"]
       [else
        (set-box! remaining (cdr xs))
        (car xs)]))
   #:name "mock"))

(define g
  (grammar
   (system "Answer shortly.")
   (user "Choose: " (select "a" "b" "c"))
   (assistant (gen 4))))

(define g*
  (eval (make-sequence-model '("b" "ok")) g))

(check-equal?
 (grammar->messages g*)
 (list
  (chat-message 'system "Answer shortly.")
  (chat-message 'user "Choose: b")
  (chat-message 'assistant "ok")))

(check-equal?
 (grammar->messages (eval (make-sequence-model '("unused")) g*))
 (grammar->messages g*))
