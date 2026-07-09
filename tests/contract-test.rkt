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
                           ban
                           weight
                           generate
                           generation-result-text
                           generation-metrics-filter-step-calls))])
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
                           Filter
                           Watcher
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
                           log-softmax
                           sequence-logprob
                           sample-id
                           make-tokenizer
                           make-provider
                           make-mock-provider
                           mock-provider
                           make-lit-filter
                           make-rx-filter
                           make-pure-filter
                           make-seq-filter
                           make-choice-filter
                           make-repeat-filter
                           make-bind-filter
                           make-score-filter
                           make-text-filter
                           make-rank-watcher
                           make-ban-watcher
                           make-weighted-rule
                           make-weighted-watcher
                           neg-inf
                           log-score-add
                           log-score-dead?
                           log-score>?
                           filter-initial
                           filter-step
                           filter-allowed-ids
                           filter-accepting?
                           filter-terminal?
                           filter-dead?
                           filter-score
                           filter-potential
                           filter-value
                           filter-token-ids
                           filter-trace
                           FilterState
                           filter-accepted-score
                           fit-weighted-watcher
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
                           select-token
                           sampler-select-token
                           make-sampler
                           Sampler
                           candidate-ids
                           top-k-ids
                           make-rng
                           gumbel
                           token-selection
                           token-selection-id
                           token-selection-lm-logprob
                           token-selection-dead-count
                           token-selection-next-state
                           token-selection-candidate-count
                           rx-machine
                           compile-regex-machine))])
      (check-equal? (exported-value core-module name)
                    'missing
                    (format "~a should not be exported" name)))

    (check-not-equal? (exported-value llama-cpp-module 'llama-cpp-model)
                      'missing)
    (check-equal? (exported-value llama-cpp-module 'make-llama-cpp-backend)
                  'missing))

  (test-case "unsupported regex constructs fail at builder construction"
    (check-exn #rx"unsupported backreference"
               (lambda () (rx "(a)\\1")))
    (check-exn #rx"unsupported regex group"
               (lambda () (rx "(?=a)a")))
    (check-exn #rx"unsupported regex anchor"
               (lambda () (rx "^a")))
    (check-true (procedure? (rx "a")))))
