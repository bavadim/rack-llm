#lang typed/racket/base

(require typed/rackunit
         "../../private/filter.rkt"
         "../../private/logits.rkt"
         "../../private/sampling.rkt")

(module+ test
  (test-case "sample-id is deterministic with equivalent rng state"
    (define logits : (Vectorof Real) (vector 0.0 1.0 -inf.0 2.0))
    (define rng-a (make-pseudo-random-generator))
    (define rng-b (make-pseudo-random-generator))
    (parameterize ([current-pseudo-random-generator rng-a]) (random-seed 18))
    (parameterize ([current-pseudo-random-generator rng-b]) (random-seed 18))
    (check-equal? (sample-id (vector->logits-view logits) rng-a 0.7)
                  (sample-id (vector->logits-view logits) rng-b 0.7)))

  (test-case "selected lm logprob matches public log-softmax"
    (define logits : (Vectorof Real) (vector 0.0 1.0 -inf.0 2.0))
    (define f (make-lit-filter '(3)))
    (define st (filter-initial f))
    (define logits-view (vector->logits-view logits))
    (define logprobs (log-softmax logits-view))
    (define selection
      (sampler-select-token
       (make-sampler 4 'allowed-only 1.0 1.0 0.7 3)
       f
       st
       logits-view
       0.0
       0.0))
    (check-equal? (token-selection-id selection) 3)
    (check-equal? (token-selection-lm-logprob selection)
                  (vector-ref logprobs 3))))
