# API

## Imports

```racket
(require rack-llm
         rack-llm/model-qwen)
```

## Model

```racket
(qwen-model #:model-path path
            #:command command
            #:context-size 512
            #:threads 1
            #:seed 0)
```

Returns a `Model`.

```racket
(model-metadata model)  ; -> hash
(model-close! model)    ; -> (-> Void)
```

Tokenizer, provider, and logits interfaces are private runtime details.

## Filters

```racket
(lit text)
(rx pattern)
(pure value)
(seq filter-builders)
(choice filter-builders)
(repeat min-count max-count filter-builder)
(bind filter-builder continue)
(score score filter-builder ban?)
(text max-tokens watcher-builders)

(rank score text)
(ban text)
(weight samples specs)
```

These functions return immutable builders. `generate` compiles a builder with
the model tokenizer internally:

```racket
(define filter
  (choice (list (lit " yes")
                (lit " no"))))
```

`seq` and `choice` take lists of filter builders.

## Generate

```racket
(generate model prompt filter-builder
          #:beta 1.0
          #:lambda 0.5
          #:temperature 0.7
          #:seed #f
          #:deadline-ms #f
          #:max-tokens 128
          #:candidate-policy 'full-vocab)
```

Candidate policies:

```text
'full-vocab
'allowed-only
'(top-k K)
```

`'full-vocab` is exact over the model vocabulary. For large vocabularies and
open text watchers this can be expensive; use `#:deadline-ms` to fail closed
instead of relying on an external timeout.

The result contains generated text and token ids:

```racket
(generation-result-text result)
(generation-result-token-ids result)
```

## Private Runtime

Tokenizer/provider state, logits views, filter state, regex machines, and
sampling selection helpers are private implementation details. User code should
choose a model, define a filter builder, and call `generate`.
