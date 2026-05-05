#lang racket/base

(require racket/list
         rackunit
         rack-llm)

(define (make-recording-model outputs requests)
  (define remaining (box outputs))
  (make-chat-model
   (lambda (req)
     (set-box! requests (cons req (unbox requests)))
     (define xs (unbox remaining))
     (cond
       [(null? xs) (error 'recording "no output left")]
       [else
        (set-box! remaining (cdr xs))
        (car xs)]))
   #:name "recording"))

(define static-requests (box '()))
(define static-chat
  (chat
   (system (lit "You are concise."))
   (user (lit "Hello"))))

(check-equal?
 (grammar->messages (eval (make-recording-model '() static-requests) static-chat))
 (list
  (chat-message 'system "You are concise.")
  (chat-message 'user "Hello")))
(check-equal? (unbox static-requests) '())

(define dynamic-requests (box '()))
(define dynamic-select (select (lit "a") (lit "ab")))
(define dynamic-gen (gen 4))
(define dynamic-chat
  (chat
   (system (lit "You are concise."))
   (user
    (lit "Choose: ")
    dynamic-select
    (lit "c"))
   (assistant dynamic-gen)))

(check-equal?
 (grammar->messages
  (eval
   (make-recording-model
    (list
     (seq (lit "Choose: ")
          (selected-node dynamic-select (lit "ab"))
          (lit "c"))
     (generated-node dynamic-gen "ok"))
    dynamic-requests)
   dynamic-chat))
 (list
  (chat-message 'system "You are concise.")
  (chat-message 'user "Choose: abc")
  (chat-message 'assistant "ok")))

(define s1 (select (lit "x") (lit "y")))
(define g1 (gen 5))
(define value-requests (box '()))
(define value-result
  (eval (make-recording-model
         (list (selected-node s1 (lit "y"))
               (generated-node g1 "hello"))
         value-requests)
        (chat
         (user s1)
         (assistant g1))))

(check-equal? (value value-result s1) (lit "y"))
(check-equal? (value value-result g1) "hello")
(check-true (selected-node? (message-body (first (chat-ast-messages value-result)))))
(check-true (generated-node? (message-body (second (chat-ast-messages value-result)))))
(check-equal?
 (grammar->messages value-result)
 (list (chat-message 'user "y")
       (chat-message 'assistant "hello")))

(define nested-gen (gen 3))
(define nested-select
  (select (seq (lit "a") nested-gen)
          (lit "b")))
(define nested-result
  (eval (make-recording-model
         (list (selected-node nested-select
                              (seq (lit "a")
                                   (generated-node nested-gen "xx"))))
         (box '()))
        (chat (assistant nested-select))))
(check-equal? (value nested-result nested-select)
              (seq (lit "a") (generated-node nested-gen "xx")))
(check-equal? (value nested-result nested-gen) "xx")

(define ordered-requests (reverse (unbox dynamic-requests)))
(check-equal? (length ordered-requests) 2)
(check-equal?
 (grammar-request-messages (first ordered-requests))
 (list (chat-message 'system "You are concise.")))
(check-true (seq-node? (grammar-request-part (first ordered-requests))))
(check-true (gen-node? (grammar-request-part (second ordered-requests))))

(check-exn
 #rx"grammar contains generated nodes"
 (lambda ()
   (grammar->messages (chat (assistant (gen 10))))))
