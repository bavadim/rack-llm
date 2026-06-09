#lang racket/base

(require racket/stream
         rackunit
         rack-llm
         rack-llm/backends/openai-responses)

(define openai-responses-e2e
  (test-suite
   "OpenAI Responses e2e acceptance tests"

   (test-case "real OpenAI Responses API completes a constrained selection"
     (define complete
       (make-openai-responses-llm
        #:model (or (getenv "RACK_LLM_OPENAI_MODEL") "gpt-5.4-nano")
        #:top-logprobs 5))
     (define choice (select (list (lit "A")) (list (list (lit "B")))))
     (define result
       (stream-first
        (eval complete
              (list
               (user (lit "Return the letter A."))
               (assistant choice)))))
     (check-not-false (member (message->string (cadr result))
                              (list "A" "B"))))))

(module+ test
  (require rackunit/text-ui)
  (cond
    [(and (getenv "RACK_LLM_OPENAI_ACCEPTANCE")
          (getenv "OPENAI_API_KEY"))
     (run-tests openai-responses-e2e)]
    [else
     (printf "Skipping OpenAI Responses acceptance tests. Set RACK_LLM_OPENAI_ACCEPTANCE=1 and OPENAI_API_KEY to run them.~n")]))
