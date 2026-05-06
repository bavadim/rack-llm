#lang racket/base

(require racket/list
         rackunit)

(define (module-export-names module-path)
  (dynamic-require module-path #f)
  (define-values (_value-exports syntax-exports)
    (module->exports module-path))
  (sort
   (for/list ([phase-group (in-list syntax-exports)]
              #:when (equal? (first phase-group) 0)
              [binding (in-list (rest phase-group))])
     (first binding))
   symbol<?))

(define expected-core-exports
  '(Part
    Completer
    Role
    assistant
    chat
    chat-messages
    chat?
    completed-message
    completed-message-content
    completed-message-role
    completed-message?
    eval
    gen
    gen-max-tokens
    gen?
    generated
    generated-source
    generated-text
    generated?
    grammar->messages
    lit
    lit-value
    lit?
    message
    message-body
    message-role
    message?
    part?
    select
    select-first
    select-rest
    select?
    selected
    selected-choice
    selected-source
    selected?
    seq
    seq-parts
    seq?
    struct:chat
    struct:completed-message
    struct:gen
    struct:generated
    struct:lit
    struct:message
    struct:select
    struct:selected
    struct:seq
    system
    user
    value))

(define expected-llama-cpp-exports
  '(make-llama-cpp-model))

(define public-api-contract
  (test-suite
   "public API contract"

   (test-case "rack-llm exports are intentional"
     (check-equal? (module-export-names 'rack-llm)
                   (sort expected-core-exports symbol<?)))

   (test-case "llama.cpp backend exports are intentional"
     (check-equal? (module-export-names 'rack-llm/backends/llama-cpp)
                   (sort expected-llama-cpp-exports symbol<?)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests public-api-contract))
