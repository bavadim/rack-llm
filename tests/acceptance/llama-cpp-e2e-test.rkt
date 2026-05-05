#lang racket/base

(require racket/list
         racket/string
         rackunit
         rackunit/text-ui
         rack-llm
         rack-llm/backends/llama-cpp)

(define acceptance-enabled?
  (getenv "RACK_LLM_ACCEPTANCE"))

(define server-url
  (or (getenv "RACK_LLM_LLAMA_SERVER")
      "http://127.0.0.1:8080"))

(define llama-cpp-e2e
  (test-suite
   "llama.cpp e2e acceptance tests"

   (test-case "real llama.cpp server completes a constrained selection"
     (define choice
       (select (lit "red") (lit "blue")))
     (define model
       (make-llama-cpp-model
        #:server-url server-url))

     (define result
       (eval model
             (chat
              (system (lit "Return exactly one allowed token."))
              (assistant choice))))

     (define selected (value result choice))
     (check-not-false (member selected (list (lit "red") (lit "blue"))))
     (check-not-false
      (member (chat-message-content (second (grammar->messages result)))
              (list "red" "blue"))))))

(module+ test
  (cond
    [acceptance-enabled?
     (run-tests llama-cpp-e2e)]
    [else
     (printf "Skipping llama.cpp acceptance tests. Set RACK_LLM_ACCEPTANCE=1 and RACK_LLM_LLAMA_SERVER to run them.~n")]))
