# API

## Imports

```racket
(require rack-llm
         rack-llm/model-llama-cpp)
```

## Model

```racket
(llama-cpp-model #:model-path gguf-path
                 #:context-size 512
                 #:threads 1
                 #:gpu-layers -1)
```

It requires the native shim built by `make native-llama`, or
`RACK_LLM_LLAMA_NATIVE_LIB` pointing at the shim. The shim wraps the official
llama.cpp C API (`llama_model_load_from_file`, `llama_decode`,
`llama_get_logits_ith`, tokenizer/detokenizer functions), so full-vocabulary
logits stay in process instead of crossing JSON/base64 IPC.

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

`'full-vocab` is exact over the model vocabulary. Each generated token requires
one complete vocabulary pass, so use `#:max-tokens` to bound generation depth
for open text watchers. `#:deadline-ms` is a coarse guard between generation
steps; it does not interrupt one exact full-vocabulary sampling pass.

The result contains generated text and token ids:

```racket
(generation-result-text result)
(generation-result-token-ids result)
```

Deterministic forced tokens may be fast-forwarded without a provider logits
request; those tokens contribute `0.0` to `generation-result-lm-logprob`.

## Private Runtime

Tokenizer/provider state, logits views, filter state, regex machines, and
sampling selection helpers are private implementation details. User code should
choose a model, define a filter builder, and call `generate`.
