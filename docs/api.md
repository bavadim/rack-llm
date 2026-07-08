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
(model-tokenizer model) ; -> Tokenizer
(model-provider model)  ; -> Provider
(model-close! model)    ; -> (-> Void)
(model-metadata model)  ; -> hash
```

## Tokenizer Interface

Model implementations construct tokenizers with:

```racket
(tokenizer #:tokenize proc
           #:detokenize proc
           #:token-ref proc
           #:vocab-size n
           #:fingerprint fp)
```

Users normally call interface operations:

```racket
(tokenize tok text)      ; -> TokenIds
(detokenize tok ids)     ; -> String
(token-ref tok id)       ; -> String
(vocab-size tok)         ; -> Natural
(fingerprint tok)        ; -> String
```

## Provider Interface

Model implementations construct providers with:

```racket
(provider #:vocab-size n
          #:next-logits proc
          #:mode 'exact-full-vocab
          #:metadata metadata
          #:start-session start
          #:next-logits/session next
          #:commit-token! commit
          #:end-session! end)
```

No mock provider is exported by the library.

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

These functions return immutable builders. Apply a builder to a tokenizer to
compile a token-native `Filter` before calling `generate`:

```racket
(define filter
  ((choice (list (lit " yes")
                 (lit " no")))
   tok))
```

`seq` and `choice` take lists of filter builders.

## Generate

```racket
(generate provider prompt-ids filter
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

The result contains generated token ids. Detokenize explicitly:

```racket
(detokenize tok (generation-result-token-ids result))
```
