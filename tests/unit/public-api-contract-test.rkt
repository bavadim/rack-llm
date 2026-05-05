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
    Role
    assistant
    chat
    chat-ast
    chat-ast-messages
    chat-ast-values
    chat-ast?
    chat-message
    chat-message-content
    chat-message-role
    chat-message?
    chat-model
    chat-model-complete
    chat-model-name
    chat-model?
    chat?
    eval
    gen
    gen-node
    gen-node-max-tokens
    gen-node?
    generated-node
    generated-node-source
    generated-node-text
    generated-node?
    grammar->messages
    grammar-request
    grammar-request-messages
    grammar-request-part
    grammar-request?
    lit
    lit-node
    lit-node-value
    lit-node?
    make-chat
    make-chat-model
    message
    message-body
    message-role
    message?
    model-complete
    part?
    select
    select-node
    select-node-first
    select-node-rest
    select-node?
    selected-node
    selected-node-choice
    selected-node-source
    selected-node?
    seq
    seq-node
    seq-node-parts
    seq-node?
    struct:chat-ast
    struct:chat-message
    struct:chat-model
    struct:gen-node
    struct:generated-node
    struct:grammar-request
    struct:lit-node
    struct:message
    struct:select-node
    struct:selected-node
    struct:seq-node
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
