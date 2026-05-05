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

(define core-examples
  (test-suite
   "core chat grammar examples"

   (test-case "static chats render without calling the model"
     (define requests (box '()))
     (define program
       (chat
        (system (lit "You are concise."))
        (user (lit "Hello"))))

     (check-equal?
      (grammar->messages (eval (make-recording-model '() requests) program))
      (list
       (chat-message 'system "You are concise.")
       (chat-message 'user "Hello")))
     (check-equal? (unbox requests) '()))

   (test-case "select and gen nodes become readable transcript text"
     (define requests (box '()))
     (define choice (select (lit "a") (lit "ab")))
     (define answer (gen 4))
     (define program
       (chat
        (system (lit "You are concise."))
        (user
         (lit "Choose: ")
         choice
         (lit "c"))
        (assistant answer)))

     (define result
       (eval
        (make-recording-model
         (list
          (seq (lit "Choose: ")
               (selected-node choice (lit "ab"))
               (lit "c"))
          (generated-node answer "ok"))
         requests)
        program))

     (check-equal?
      (grammar->messages result)
      (list
       (chat-message 'system "You are concise.")
       (chat-message 'user "Choose: abc")
       (chat-message 'assistant "ok")))
     (check-equal? (value result choice) (lit "ab"))
     (check-equal? (value result answer) "ok"))

   (test-case "evaluated AST preserves result nodes"
     (define choice (select (lit "x") (lit "y")))
     (define answer (gen 5))
     (define result
       (eval (make-recording-model
              (list (selected-node choice (lit "y"))
                    (generated-node answer "hello"))
              (box '()))
             (chat
              (user choice)
              (assistant answer))))

     (check-true (selected-node? (message-body (first (chat-ast-messages result)))))
     (check-true (generated-node? (message-body (second (chat-ast-messages result)))))
     (check-equal?
      (grammar->messages result)
      (list (chat-message 'user "y")
            (chat-message 'assistant "hello"))))

   (test-case "nested dynamic nodes record values from the selected branch"
     (define nested-answer (gen 3))
     (define nested-choice
       (select (seq (lit "a") nested-answer)
               (lit "b")))

     (define result
       (eval (make-recording-model
              (list (selected-node nested-choice
                                   (seq (lit "a")
                                        (generated-node nested-answer "xx"))))
              (box '()))
             (chat (assistant nested-choice))))

     (check-equal? (value result nested-choice)
                   (seq (lit "a") (generated-node nested-answer "xx")))
     (check-equal? (value result nested-answer) "xx"))

   (test-case "model requests receive only previous evaluated messages"
     (define requests (box '()))
     (define choice (select (lit "a") (lit "ab")))
     (define answer (gen 4))

     (eval
      (make-recording-model
       (list
        (seq (lit "Choose: ")
             (selected-node choice (lit "ab"))
             (lit "c"))
        (generated-node answer "ok"))
       requests)
      (chat
       (system (lit "You are concise."))
       (user (lit "Choose: ") choice (lit "c"))
       (assistant answer)))

     (define ordered-requests (reverse (unbox requests)))
     (check-equal? (length ordered-requests) 2)
     (check-equal?
      (grammar-request-messages (first ordered-requests))
      (list (chat-message 'system "You are concise.")))
     (check-true (seq-node? (grammar-request-part (first ordered-requests))))
     (check-true (gen-node? (grammar-request-part (second ordered-requests)))))

   (test-case "unevaluated dynamic chats cannot be rendered"
     (check-exn
      #rx"grammar contains generated nodes"
      (lambda ()
        (grammar->messages (chat (assistant (gen 10)))))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests core-examples))
