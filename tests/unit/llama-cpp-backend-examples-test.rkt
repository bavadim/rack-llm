#lang racket/base

(require racket/list
         racket/stream
         rackunit
         rack-llm
         rack-llm/backends/llama-cpp)

(define llama-cpp-backend-examples
  (test-suite
   "llama.cpp backend examples"

   (test-case "backend is a token oracle and core reduces AST locally"
     (define captured-prompts (box '()))

     (define (fake-generate prompt)
       (set-box! captured-prompts (cons prompt (unbox captured-prompts)))
       (list (token-candidate "Choose: ab ok" 0.0)))

     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define answer (gen 4))
     (define complete
       (make-llama-cpp-llm
        #:generate fake-generate))

(define result
        (stream-first
         (eval complete
               (list
                (system (lit "You are concise."))
                (assistant (lit "Choose: ") choice (lit " ") answer)))))

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
     (check-equal? (last (unbox captured-prompts)) "system: You are concise."))

   (test-case "post-match prefers the longest valid selected branch"
     (define choice (select (list (lit "a")) (list (list (lit "ab")))))
     (define complete
       (make-llama-cpp-llm
        #:generate (lambda (_prompt) (list (token-candidate "abc" 0.0)))))

(define result
        (stream-first
         (eval complete
               (list (assistant choice (lit "c"))))))

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
