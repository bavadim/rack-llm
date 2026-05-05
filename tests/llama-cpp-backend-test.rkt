#lang racket/base

(require racket/string
         rackunit
         rack-llm
         rack-llm/backends/llama-cpp)

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
(check-true (string-contains? grammar "start: \"Choose: \" SEL_1 \" \" GEN_2"))
(check-true (string-contains? grammar "SEL_1_0[capture=\"select:SEL_1:0\"]: \"a\""))
(check-true (string-contains? grammar "SEL_1_1[capture=\"select:SEL_1:1\"]: \"ab\""))
(check-true (string-contains? grammar "SEL_1: SEL_1_0 | SEL_1_1"))
(check-true (string-contains? grammar "GEN_2[capture=\"gen:GEN_2\", max_tokens=4]: /(?s:.*)/"))

(define prefix-choice (select (lit "a") (lit "ab")))
(define prefix-model
  (make-llama-cpp-model
   #:generate (lambda (_prompt _grammar) "abc")))

(define prefix-result
  (eval prefix-model
        (chat (assistant (seq prefix-choice (lit "c"))))))

(check-equal?
 (grammar->messages prefix-result)
 (list (chat-message 'assistant "abc")))
(check-equal? (value prefix-result prefix-choice) (lit "ab"))
