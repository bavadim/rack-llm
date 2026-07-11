#lang racket/base

(require racket/runtime-path
         rackunit
         "../main.rkt")

(define-runtime-path core-module "../main.rkt")
(define-runtime-path llama-cpp-module "../model-llama-cpp.rkt")

(define (exported-value module-path name)
  (with-handlers ([exn:fail? (lambda (_exn) 'missing)])
    (dynamic-require module-path name (lambda () 'missing))))

(module+ test
  (test-case "public API exports only the model-level generation surface"
    (for ([name (in-list '(model-metadata
                           model-close!
                           lit
                           rx
                           pure
                           seq
                           choice
                           repeat
                           bind
                           score
                           text
                           rank
                           rank-rx
                           ban
                           ban-rx
                           weight
                           local-sampler
                           cars-sampler
                           make-generator
                           generator-sample!
                           generator-sample-n!
                           generator-close!
                           generate
                           generation-result-text
                           generation-metrics-guidance-step-calls))])
      (check-not-equal? (exported-value core-module name)
                        'missing
                        (format "~a should be exported" name)))

    (for ([name (in-list '(TokenId
                           TokenIds
                           Logit
                           Logits
                           ProviderMode
                           Tokenizer
                           Provider
                           Program
                           Guidance
                           TextObserver
                           tokenizer
                           provider
                           model
                           tokenize
                           detokenize
                           token-ref
                           vocab-size
                           fingerprint
                           provider-next-logits
                           provider-session-supported?
                           provider-vocab-size
                           provider-mode
                           provider-metadata
                           model-tokenizer
                           model-provider
                           sequence-logprob
                           make-tokenizer
                           make-provider
                           make-mock-provider
                           mock-provider
                           make-lit-program
                           make-rx-program
                           make-pure-program
                           make-seq-program
                           make-choice-program
                           make-repeat-program
                           make-bind-program
                           make-score-program
                           make-text-program
                           make-rank-observer
                           make-ban-observer
                           make-rx-rank-observer
                           make-rx-ban-observer
                           make-weighted-rule
                           make-weighted-observer
                           neg-inf
                           log-score-add
                           log-score-dead?
                           guidance-initial
                           guidance-step
                           guidance-accepting?
                           guidance-terminal?
                           guidance-dead?
                           guidance-score
                           guidance-potential
                           guidance-value
                           guidance-token-ids
                           guidance-trace
                           GuidanceState
                           guidance-accepted-score
                           fit-weighted-observer
                           check
                           check-result
                           generate-stream
                           found?
                           not-found?
                           hard-failure?
                           low-score?
                           provider-error?
                           generation-result-guide-score
                           min-guide-score
                           min-total-score
                           score-filter
                           lit-filter
                           generation-metrics-runtime-step-calls
                           candidate-ids
                           make-rng
                           gumbel
                           rx-machine
                           compile-regex-machine))])
      (check-equal? (exported-value core-module name)
                    'missing
                    (format "~a should not be exported" name)))

    (check-not-equal? (exported-value llama-cpp-module 'llama-cpp-model)
                      'missing)
    (check-equal? (exported-value llama-cpp-module 'make-llama-cpp-backend)
                  'missing))

  (test-case "regex builders expose PCRE2's DFA-compatible syntax"
    (check-exn #rx"unsupported backreference"
               (lambda () (rx "(a)\\1")))
    (check-exn #rx"unsupported capture-dependent conditional"
               (lambda () (rx "(a)(?(1)b|c)")))
    (for ([pattern (in-list '("a"
                              "(?<=a)b"
                              "(?>ab|a)b"
                              "\\p{L}+"
                              "(?i)\\brefund\\b"
                              "(?i:\\brefund\\b)"
                              "(?i:a)(?-i:b)"
                              "[[:alpha:]][[:word:]]+"
                              "(?is)[\\s\\S]{3,20}"
                              "(?m)^\\s*(?:[-*+]|\\d+[.)])\\s+\\S+"))])
      (check-not-exn (lambda () (rx pattern))
                     (format "~a should be supported" pattern)))))
