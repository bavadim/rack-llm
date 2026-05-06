#lang racket/base

(require racket/list
         rackunit
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
       (select (list (lit "red")) (list (list (lit "blue")))))
     (define complete
       (make-llama-cpp-model
        #:server-url server-url))

     (define result
       (eval complete
             (list
              (system (lit "Return exactly one allowed token."))
              (assistant choice))))

     (define selected (selected-choice (first (message-body (second result)))))
     (check-not-false (member selected (list (list (lit "red")) (list (lit "blue")))))
     (check-not-false
      (member (fixed-body->string (message-body (second result)))
              (list "red" "blue"))))))

(module+ test
  (require rackunit/text-ui)
  (cond
    [acceptance-enabled?
     (run-tests llama-cpp-e2e)]
    [else
     (printf "Skipping llama.cpp acceptance tests. Set RACK_LLM_ACCEPTANCE=1 and RACK_LLM_LLAMA_SERVER to run them.~n")]))
