# Migrating from TokenOracle to Provider v2

The original public API treats a model as a `TokenOracle`:

```racket
#lang racket

(require rack-llm)

(define (oracle transcript prefix)
  (list (token-candidate "A" -0.1)
        (token-candidate "B" -2.0)))

(eval oracle (list (assistant (gen 1))))
```

That still works for examples and compatibility code. Research runs should
prefer Provider v2 because it records the model identity, provider mode,
tokenization policy, explicit state, and trace fields.

## New Mock Provider Example

```racket
#lang racket

(require rack-llm
         rack-llm/providers/mock-provider
         rack-llm/providers/provider-v2)

(define p
  (make-mock-provider
   #:vocab '("A" "B")
   #:default-logits '#(0.0 -2.0)))

(require-exact-provider p)

(eval (provider->token-oracle p)
      (list (assistant (gen 1))))
```

`provider->token-oracle` lets existing `eval` code run while the sampler is
migrated toward Provider v2-native entry points.

## Compatibility Adapter

Legacy oracles can be wrapped when a pipeline expects a provider:

```racket
(define compat
  (token-oracle->provider oracle
                          #:name 'legacy-demo
                          #:model-id "legacy"
                          #:vocab '("A" "B")))
```

The default mode is `compat-no-logits`. This is intentional: a legacy
`TokenOracle` returns only observed candidates, not a full vocabulary
distribution.

## Exact vs Truncated

Use `require-exact-provider` before synthetic exactness tests. It accepts only
`exact-full-vocab` providers and rejects `truncated-top-k` or `compat-no-logits`
providers with a clear error.

OpenAI Responses top logprobs and HTTP llama.cpp top-logprob endpoints are
compatibility or truncated providers. They can be used for demos and weak
baselines, but not for exact distribution experiments in the paper.
