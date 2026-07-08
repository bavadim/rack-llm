# rack-llm

`rack-llm` is a typed token-native core for controlled generation.

The public model is:

```text
Provider + prompt token ids + Filter -> generation-result
```

Text exists at the edges. Tokenization and detokenization are supplied by a
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

A model provides a tokenizer and provider together:

```racket
(define m
  (qwen-model #:model-path "/mnt/storage/models/qwen/Qwen3.5-4B"
              #:command sidecar-command))

(define tok (model-tokenizer m))
(define p (model-provider m))
```

Filters are built with explicit tokenizers:

```racket
(define f
  (choice (list (lit tok " yes")
                (lit tok " no"))))

(define r
  (generate p
            (tokenize tok "Reply yes or no:")
            f
            #:candidate-policy 'allowed-only))

(detokenize tok (generation-result-token-ids r))
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
main.rkt        public core: interfaces, filters, regex, generation
model-qwen.rkt  Qwen sidecar model implementation
```

There is no compatibility layer for the old guide/runtime API, no mock provider
in the library, and no public `make-*` constructors.
