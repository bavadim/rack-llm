#lang racket/base

(require racket/list
         racket/string
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

     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define answer (gen 4))
     (define complete
       (make-llama-cpp-model
        #:generate fake-generate))

     (define result
       (eval complete
             (list
              (system (lit "You are concise."))
              (assistant (lit "Choose: ") choice (lit " ") answer))))

     (check-equal?
      result
      (list (message 'system (list (lit "You are concise.")))
            (message 'assistant
                     (list (lit "Choose: ")
                           (selected choice (list (lit "ab")))
                           (lit " ")
                           (generated answer "ok")))))
     (define assistant-body (message-body (second result)))
     (check-equal? (selected-choice (second assistant-body)) (list (lit "ab")))
     (check-equal? (generated-text (fourth assistant-body)) "ok")
     (check-equal? (unbox captured-prompt) "system: You are concise.")

     (define grammar (unbox captured-grammar))
     (check-true (string-prefix? grammar "%llguidance"))
     (check-true (string-contains? grammar "start: \"Choose: \" sel_1 \" \" gen_2"))
     (check-true (string-contains? grammar "sel_1_0[capture=\"select:sel_1:0\"]: \"a\""))
     (check-true (string-contains? grammar "sel_1_1[capture=\"select:sel_1:1\"]: \"ab\""))
     (check-true (string-contains? grammar "sel_1: sel_1_0 | sel_1_1"))
     (check-true (string-contains? grammar "gen_2[capture=\"gen:gen_2\", max_tokens=4]: /(?s:.*)/")))

   (test-case "post-match prefers the longest valid selected branch"
     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define complete
       (make-llama-cpp-model
        #:generate (lambda (_prompt _grammar) "abc")))

     (define result
       (eval complete
             (list (assistant choice (lit "c")))))

     (check-equal?
      result
      (list (message 'assistant
                     (list (selected choice (list (lit "ab")))
                           (lit "c")))))
     (check-equal? (selected-choice (first (message-body (first result))))
                   (list (lit "ab"))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests llama-cpp-backend-examples))
