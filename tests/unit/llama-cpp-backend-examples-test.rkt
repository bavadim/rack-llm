#lang racket/base

(require racket/string
         rackunit
         rack-llm
         rack-llm/backends/llama-cpp)

(define llama-cpp-backend-examples
  (test-suite
   "llama.cpp backend examples"

   (test-case "backend compiles select and gen nodes to llguidance captures"
     (define captured-prompt (box #f))
     (define captured-grammar (box #f))

     (define (fake-generate prompt grammar)
       (set-box! captured-prompt prompt)
       (set-box! captured-grammar grammar)
       "Choose: ab ok")

     (define choice (select (lit "a") (lit "ab")))
     (define answer (gen 4))
     (define model
       (make-llama-cpp-model
        #:generate fake-generate))

     (define part
       (seq (lit "Choose: ")
            choice
            (lit " ")
            answer))

     (define result
       (eval model
             (chat
              (system (lit "You are concise."))
              (assistant part))))

     (check-equal?
      (grammar->messages result)
      (list (chat-message 'system "You are concise.")
            (chat-message 'assistant "Choose: ab ok")))
     (check-equal? (value result choice) (lit "ab"))
     (check-equal? (value result answer) "ok")
     (check-equal? (unbox captured-prompt) "system: You are concise.")

     (define grammar (unbox captured-grammar))
     (check-true (string-prefix? grammar "%llguidance"))
     (check-true (string-contains? grammar "start: \"Choose: \" sel_1 \" \" gen_2"))
     (check-true (string-contains? grammar "sel_1_0[capture=\"select:sel_1:0\"]: \"a\""))
     (check-true (string-contains? grammar "sel_1_1[capture=\"select:sel_1:1\"]: \"ab\""))
     (check-true (string-contains? grammar "sel_1: sel_1_0 | sel_1_1"))
     (check-true (string-contains? grammar "gen_2[capture=\"gen:gen_2\", max_tokens=4]: /(?s:.*)/")))

   (test-case "post-match prefers the longest valid selected branch"
     (define choice (select (lit "a") (lit "ab")))
     (define model
       (make-llama-cpp-model
        #:generate (lambda (_prompt _grammar) "abc")))

     (define result
       (eval model
             (chat (assistant (seq choice (lit "c"))))))

     (check-equal?
      (grammar->messages result)
      (list (chat-message 'assistant "abc")))
     (check-equal? (value result choice) (lit "ab")))))

(module+ test
  (require rackunit/text-ui)
  (run-tests llama-cpp-backend-examples))
