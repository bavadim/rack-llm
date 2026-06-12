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
                   (list (lit "ab"))))

   (test-case "backend accepts a custom prompt renderer"
     (define captured-prompts (box '()))
     (define (render-prompt transcript prefix)
       (format "messages=~a; assistant=~a"
               (length transcript)
               prefix))
     (define complete
       (make-llama-cpp-llm
        #:render-prompt render-prompt
        #:generate
        (lambda (prompt)
          (set-box! captured-prompts (cons prompt (unbox captured-prompts)))
          (list (token-candidate "a" 0.0)))))
     (define choice
       (select (list (lit "a"))
               (list (list (lit "b")))))

     (stream-first
      (eval complete
            (list
             (user (lit "Return a."))
             (assistant choice))))

     (check-equal? (last (unbox captured-prompts))
                   "messages=1; assistant="))

   (test-case "evaluated repetitions render into later prompts"
     (define captured-prompts (box '()))
     (define repeated-as
       (at-least-once (list (lit "a"))))
     (define complete
       (make-llama-cpp-llm
        #:generate
        (lambda (prompt)
          (set-box! captured-prompts (cons prompt (unbox captured-prompts)))
          (if (string=? prompt "")
              (list (token-candidate "aa" 0.0))
              (list (token-candidate "ok" 0.0))))))

     (define result
       (stream-first
        (eval complete
              (list
               (assistant repeated-as)
               (assistant (gen 2))))))

     (check-equal?
      result
      (list
       (message 'assistant (list (repeated repeated-as "aa")))
       (message 'assistant (list (generated (gen 2) "ok")))))
     (check-not-false
      (member "assistant: aa" (unbox captured-prompts))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests llama-cpp-backend-examples))
