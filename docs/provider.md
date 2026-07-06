# Provider Contract

A provider supplies model logits for `(prompt, prefix)` pairs.

```racket
(make-provider
 #:vocab vocab
 #:next-logits next-logits
 #:mode 'exact-full-vocab
 #:metadata metadata
 #:tokenize tokenize-proc
 #:detokenize detokenize-proc)
```

## Fields

| Field | Meaning |
|---|---|
| `provider-vocab` | List of token strings. Vector positions are token ids. |
| `provider-next-logits` | Callback `(prompt prefix) -> logits`. |
| `provider-mode` | One of `exact-full-vocab`, `top-k-approx`, `mock`. |
| `provider-metadata` | Free-form metadata for model name, path, hash, etc. |
| `provider-tokenize` | Optional callback `(text -> token-id-list)`. |
| `provider-detokenize` | Optional callback `(token-id-list -> text)`. |

If tokenizer callbacks are absent, the provider uses a longest-string match over
`provider-vocab`. That fallback is suitable for tests and toy vocabularies only.
Paper-grade local model experiments must use the model tokenizer through the
provider callbacks or a sidecar.

## Modes

| Mode | Contract |
|---|---|
| `exact-full-vocab` | `next-logits` must return a vector with one real logit per vocab item. |
| `mock` | Same full-vector contract, used for deterministic tests/examples. |
| `top-k-approx` | May return a full vector, hash, or sparse token/logit list. Missing ids are `-inf.0`. |

Hard decoding needs full logits or a top-k result that includes at least one
valid token. If an approximate provider omits every viable token, generation
returns `status='error-approx-provider` instead of pretending the guide itself
failed.

## Mock Provider

```racket
(make-mock-provider
 #:vocab '("yes" "no")
 #:default-logits '#(0.0 -1.0)
 #:prefix-logits (hash "yes" '#(-2.0 0.0)))
```

The mock provider has `provider-mode` equal to `mock`.

## llama.cpp Sidecar Operations

The local sidecar used by `make-llama-cpp-provider` must support:

```json
{"op":"load","model_path":"...","context_size":512,"threads":1,"seed":0}
{"op":"tokenize","text":"..."}
{"op":"detokenize","ids":[1,2,3]}
{"op":"next_logits","prompt":"...","prefix":"..."}
```

The response to `load` must include `vocab`. The response to `tokenize` must
include `ids`; `detokenize` must include `text`; `next_logits` must include
`logits` or `logits_b64`.
