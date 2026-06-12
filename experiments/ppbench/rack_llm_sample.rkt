#lang racket

(require json
         racket/stream
         rack-llm
         rack-llm/backends/llama-cpp)

(define request (read-json))
(define system-prompt (hash-ref request 'system_prompt))
(define user-prompt (hash-ref request 'user_prompt))

(define item
  (list
   (lit "\"")
   (gen 16)
   (lit "\"")))

(define additional-items
  (select
   '()
   (list
    (list
     (at-least-once
      (cons (lit ", ") item))))))

(define answer
  (append
   (list (lit "```json\n["))
   item
   (list additional-items
         (lit "]\n```"))))

(define oracle
  (make-llama-cpp-llm
   #:server-url "http://127.0.0.1:8080"
   #:n-probs 64))

(define started-at (current-inexact-milliseconds))

(define variants
  (eval oracle
        (list
         (system (lit system-prompt))
         (user (lit user-prompt))
         (apply assistant answer))))

(define (render-body values)
  (apply string-append (map render-value values)))

(define (render-value value)
  (cond
    [(lit? value) (lit-value value)]
    [(generated? value) (generated-text value)]
    [(selected? value) (render-body (selected-choice value))]
    [(repeated? value) (repeated-text value)]
    [else (error 'render-value "unsupported value: ~e" value)]))

(define (render-result result)
  (render-body (message-body (third result))))

(define outputs
  (for/list ([index (in-range 1 11)]
             [variant variants])
    (define output (render-result variant))
    (define elapsed-seconds
      (/ (- (current-inexact-milliseconds) started-at) 1000.0))
    (eprintf "\n=== rack-llm variant ~a/10 (+~a s) ===\n~a\n"
             index
             (~r elapsed-seconds #:precision '(= 1))
             output)
    (flush-output (current-error-port))
    output))

(write-json (hash 'outputs outputs))
(newline)
