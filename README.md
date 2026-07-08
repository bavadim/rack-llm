# rack-llm

`rack-llm` is a typed token-native core for controlled generation.

The public model is:

```text
Model + prompt text + filter builder -> generation-result
```

Tokenizer, provider, and logits state are private runtime details supplied by a
model implementation.

## Public API

Core API:

```racket
(require rack-llm)
```

Model implementation:

```racket
(require rack-llm/model-qwen)
```

A model is passed directly to `generate`:

```racket
(define m
  (qwen-model #:model-path "/mnt/storage/models/qwen/Qwen3.5-4B"
              #:command sidecar-command))
```

Filters are immutable builders. `generate` compiles them with the model
tokenizer internally:

```racket
(define f
  (choice (list (lit " yes")
                (lit " no"))))

(define r
  (generate m
            "Reply yes or no:"
            f
            #:candidate-policy 'allowed-only))

(generation-result-text r)
```

## Filters

Atomic filters:

```text
lit   exact token sequence
rx    token-level regex fullmatch
pure  accepting value without consuming tokens
text  open generation for a fixed token budget
```

Combinators:

```text
seq     ordered composition
choice  alternatives from a list of filters
repeat  bounded repetition
bind    dependent continuation
```

Soft constraints:

```text
score   reward or hard-ban wrapper
rank    watcher that rewards a token sequence inside text
ban     watcher that rejects a token sequence inside text
weight  learned weighted watcher from labeled string features
```

`generate` combines model logits and filter deltas as:

```text
lm-logit + beta * (delta-score + lambda * delta-potential)
```

## Modules

```text
main.rkt              public facade: API types, builders, generate
private/logits.rkt    logits view abstraction for provider/sampler boundary
private/model.rkt     tokenizer/provider/model runtime objects
private/filter.rkt    filter runtime state machines
private/regex.rkt     regex parser/NFA/token transition caches
private/sampling.rkt  default token selection algorithm
model-qwen.rkt        Qwen sidecar model implementation
```

There is no compatibility layer for the old guide/runtime API, no mock provider
in the library, and no public `make-*` constructors.

## E2E Scenarios

Executable public API scenarios live in `tests/e2e-real-test.rkt` and run
against the real Qwen model. They cover finite hard choices, regex hard
constraints, soft open text, and dependent `bind` composition.

## Current Repair Backlog

The core API boundary is intentionally narrow, but two repair tracks remain:

- exact full-vocabulary soft decoding needs a measured optimization pass or a
  fail-closed infeasible decision for Qwen-scale vocabularies;
- real benchmark Racket scripts still need to be aligned with the current API
  before `012_*` artifacts can be treated as fresh evidence.
