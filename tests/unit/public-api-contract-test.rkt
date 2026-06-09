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
  '(Program
    TokenOracle
    EvaluatedProgram
    assistant
    body->string
    eval
    value
    value?
    gen
    gen-max-tokens
    gen?
    generated
    generated-source
    generated-text
    generated?
    lit
    lit-value
    lit?
    message
    message-body
    message-role
    message?
    expr
    expr?
    select
    select-first
    select-rest
    select?
    selected
    selected-choice
    selected-source
    selected?
    struct:token-candidate
    struct:value
    struct:gen
    struct:generated
    struct:lit
    struct:message
    struct:expr
    struct:select
    struct:selected
    token-candidate
    token-candidate-logp
    token-candidate-text
    token-candidate?
    value->string
    message->string
    system
    user))

(define expected-llama-cpp-exports
  '(make-llama-cpp-llm))

(define expected-openai-responses-exports
  '(make-openai-responses-llm))

(define public-api-contract
  (test-suite
   "public API contract"

   (test-case "rack-llm exports are intentional"
     (check-equal? (module-export-names 'rack-llm)
                   (sort expected-core-exports symbol<?)))

     (test-case "llama.cpp backend exports are intentional"
       (check-equal? (module-export-names 'rack-llm/backends/llama-cpp)
                     (sort expected-llama-cpp-exports symbol<?)))

     (test-case "OpenAI Responses backend exports are intentional"
       (check-equal? (module-export-names 'rack-llm/backends/openai-responses)
                     (sort expected-openai-responses-exports symbol<?)))))

(module+ test
  (require rackunit/text-ui)
  (run-tests public-api-contract))
