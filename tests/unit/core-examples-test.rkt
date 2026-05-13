#lang racket/base

(require racket/list
         racket/stream
         rackunit
         rack-llm)

(define (make-recording-model outputs requests)
  (define remaining (box outputs))
  (lambda (transcript prefix)
    (set-box! requests (cons (cons transcript prefix) (unbox requests)))
    (cond
      [(not (string=? prefix "")) '()]
      [else
       (define xs (unbox remaining))
       (cond
         [(null? xs) (error 'recording "no output left")]
         [else
          (set-box! remaining (cdr xs))
          (list (token-candidate (car xs) 0.0))])])))

(define core-examples
  (test-suite
   "core chat grammar examples"

   (test-case "static chats render without calling the model"
     (define requests (box '()))
     (define program
       (list
        (system (lit "You are concise."))
        (user (lit "Hello"))))

     (check-equal?
      (stream-first (eval (make-recording-model '() requests) program))
      (list
       (message 'system (list (lit "You are concise.")))
       (message 'user (list (lit "Hello")))))
     (check-equal? (unbox requests) '()))

   (test-case "select and gen nodes become readable transcript text"
     (define requests (box '()))
     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define answer (gen 4))
     (define program
       (list
        (system (lit "You are concise."))
        (user
         (lit "Choose: ")
         choice
         (lit "c"))
        (assistant answer)))

     (define result
       (stream-first
        (eval
         (make-recording-model
          (list "Choose: abc" "ok")
          requests)
         program)))

     (check-equal?
      result
      (list
       (message 'system (list (lit "You are concise.")))
       (message 'user
                (list (lit "Choose: ")
                      (selected choice (list (lit "ab")))
                      (lit "c")))
       (message 'assistant (list (generated answer "ok")))))
     (define user-selection (second (message-body (second result))))
     (define assistant-generation (first (message-body (third result))))
     (check-equal? (selected-choice user-selection) (list (lit "ab")))
     (check-equal? (generated-text assistant-generation) "ok"))

   (test-case "evaluated AST preserves result nodes"
     (define choice (select (list (lit "x")) (list (list (lit "y")))))
     (define answer (gen 5))
     (define result
       (stream-first
        (eval (make-recording-model
               (list "y" "hello")
               (box '()))
              (list
               (user choice)
               (assistant answer)))))

     (check-true (selected? (first (message-body (first result)))))
     (check-true (generated? (first (message-body (second result)))))
     (check-equal?
      result
      (list (message 'user (list (selected choice (list (lit "y")))))
            (message 'assistant (list (generated answer "hello"))))))

   (test-case "nested dynamic nodes record values from the selected branch"
     (define nested-answer (gen 3))
     (define nested-choice
       (select (list (lit "a") nested-answer)
               (list (list (lit "b")))))

     (define result
       (stream-first
        (eval (make-recording-model
               (list "axx")
               (box '()))
              (list (assistant nested-choice)))))

     (define selected-body
       (selected-choice (first (message-body (first result)))))
     (check-equal? selected-body
                   (list (lit "a") (generated nested-answer "xx")))
     (check-equal? (generated-text (second selected-body)) "xx"))

   (test-case "model requests receive only previous evaluated messages"
     (define requests (box '()))
     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define answer (gen 4))

     (stream-first
      (eval
       (make-recording-model
        (list "Choose: abc" "ok")
        requests)
       (list
        (system (lit "You are concise."))
        (user (lit "Choose: ") choice (lit "c"))
        (assistant answer))))

     (define ordered-requests
       (filter (lambda (request) (string=? (cdr request) ""))
               (reverse (unbox requests))))
     (check-equal? (length ordered-requests) 2)
     (check-equal?
      (car (first ordered-requests))
      (list (message 'system (list (lit "You are concise.")))))
     (check-equal?
      (cdr (first ordered-requests))
      "")
     (check-equal? (cdr (second ordered-requests)) ""))))

(module+ test
  (require rackunit/text-ui)
  (run-tests core-examples))
