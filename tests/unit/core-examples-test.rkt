#lang racket/base

(require racket/list
         rackunit
         rack-llm)

(define (make-recording-model outputs requests)
  (define remaining (box outputs))
  (lambda (transcript target)
    (set-box! requests (cons (cons transcript target) (unbox requests)))
    (define xs (unbox remaining))
    (cond
      [(null? xs) (error 'recording "no output left")]
      [else
       (set-box! remaining (cdr xs))
       (car xs)])))

(define core-examples
  (test-suite
   "core chat grammar examples"

   (test-case "static chats render without calling the model"
     (define requests (box '()))
     (define program
       (chat
        (list
        (system (lit "You are concise."))
        (user (lit "Hello")))))

     (check-equal?
      (grammar->messages (eval (make-recording-model '() requests) program))
      (list
       (completed-message 'system "You are concise.")
       (completed-message 'user "Hello")))
     (check-equal? (unbox requests) '()))

   (test-case "select and gen nodes become readable transcript text"
     (define requests (box '()))
     (define choice (select (lit "a") (list (lit "ab"))))
     (define answer (gen 4))
     (define program
       (chat
        (list
        (system (lit "You are concise."))
        (user
         (lit "Choose: ")
         choice
         (lit "c"))
        (assistant answer))))

     (define result
       (eval
        (make-recording-model
         (list
          (seq (list (lit "Choose: ")
                     (selected choice (lit "ab"))
                     (lit "c")))
          (generated answer "ok"))
         requests)
        program))

     (check-equal?
      (grammar->messages result)
      (list
       (completed-message 'system "You are concise.")
       (completed-message 'user "Choose: abc")
       (completed-message 'assistant "ok")))
     (check-equal? (value result choice) (lit "ab"))
     (check-equal? (value result answer) "ok"))

   (test-case "evaluated AST preserves result nodes"
     (define choice (select (lit "x") (list (lit "y"))))
     (define answer (gen 5))
     (define result
       (eval (make-recording-model
              (list (selected choice (lit "y"))
                    (generated answer "hello"))
              (box '()))
             (chat
              (list
              (user choice)
              (assistant answer)))))

     (check-true (selected? (message-body (first (chat-messages result)))))
     (check-true (generated? (message-body (second (chat-messages result)))))
     (check-equal?
      (grammar->messages result)
      (list (completed-message 'user "y")
            (completed-message 'assistant "hello"))))

   (test-case "nested dynamic nodes record values from the selected branch"
     (define nested-answer (gen 3))
     (define nested-choice
       (select (seq (list (lit "a") nested-answer))
               (list (lit "b"))))

     (define result
       (eval (make-recording-model
              (list (selected nested-choice
                              (seq (list (lit "a")
                                         (generated nested-answer "xx")))))
              (box '()))
             (chat (list (assistant nested-choice)))))

     (check-equal? (value result nested-choice)
                   (seq (list (lit "a") (generated nested-answer "xx"))))
     (check-equal? (value result nested-answer) "xx"))

   (test-case "model requests receive only previous evaluated messages"
     (define requests (box '()))
     (define choice (select (lit "a") (list (lit "ab"))))
     (define answer (gen 4))

     (eval
      (make-recording-model
       (list
        (seq (list (lit "Choose: ")
                   (selected choice (lit "ab"))
                   (lit "c")))
        (generated answer "ok"))
       requests)
      (chat
       (list
       (system (lit "You are concise."))
       (user (lit "Choose: ") choice (lit "c"))
       (assistant answer))))

     (define ordered-requests (reverse (unbox requests)))
     (check-equal? (length ordered-requests) 2)
     (check-equal?
      (car (first ordered-requests))
      (list (completed-message 'system "You are concise.")))
     (check-true (seq? (cdr (first ordered-requests))))
     (check-true (gen? (cdr (second ordered-requests)))))

   (test-case "unevaluated dynamic chats cannot be rendered"
     (check-exn
      #rx"grammar contains generated nodes"
      (lambda ()
        (grammar->messages (chat (list (assistant (gen 10))))))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests core-examples))
