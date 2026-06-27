# Provider v2

Provider v2 is the typed boundary between the functional core and model
runtimes. It makes tokenization, model state, provider mode, and logits explicit
so experiments can report what distribution they actually sampled from.

Core modules:

- `rack-llm/providers/provider-v2`: provider structs, mode checks, adapters, and
  truncation helpers.
- `rack-llm/providers/llama-local-provider`: local stdio sidecar provider for
  full-vocabulary GGUF logits.
- `rack-llm/providers/mock-provider`: deterministic full-vocabulary provider for
  unit tests and small synthetic runs.
- `rack-llm/providers/prompt-rendering`: shared transcript plus prefix
  rendering.

## API Reference

The core provider value has five fields:

- `provider-info`: name, mode, model id/hash, and vocabulary size.
- `provider-initial-state`: explicit starting state for a run.
- `provider-tokenize`: deterministic `String -> (Listof TokenId)`.
- `provider-detokenize`: deterministic token-id decoding.
- `provider-next-logits`: `(transcript, prefix, state) -> logits-result`.

`logits-result` carries the full or truncated logit vector, the next provider
state, and `provider-trace` with prompt/prefix token counts, cache status,
elapsed milliseconds, and optional `truncated-mass`.

Provider modes:

- `exact-full-vocab`: `next-logits` returns one logit for every token id in the
  vocabulary. Use this for exact distribution and synthetic correctness tests.
- `truncated-top-k`: the provider or wrapper only exposes a top-K
  approximation. When the source provider is exact, `truncated-mass` records the
  discarded softmax mass.
- `compat-no-logits`: compatibility mode for legacy `TokenOracle` call sites.
  It must not be treated as exact.

Example:

```racket
#lang racket

(require rack-llm/providers/mock-provider
         rack-llm/providers/provider-v2)

(define p
  (make-mock-provider
   #:vocab '("a" "b" "<eos>")
   #:default-logits '#(0.0 -1.0 -10.0)))

(require-exact-provider p)
((provider-tokenize p) "ab")
```

Use `truncate-provider` for explicit top-K ablations:

```racket
(define p-top2 (truncate-provider p 2))
(provider-info-mode (provider-info p-top2)) ; 'truncated-top-k
```

Metrics tables include `provider_k` and `truncated_mass_mean` when runs record
top-K truncation data. Exact full-vocabulary runs leave those fields empty.

## Local Full-Logits Provider

Research runs that claim exact sampling need a local runtime that returns one
logit per vocabulary token. The intended constructor shape is:

```racket
(make-llama-local-provider
 #:model-path "/models/model.gguf"
 #:seed 42
 #:context-size 4096
 #:threads 8
 #:runtime 'stdio-sidecar)
```

That provider must report `exact-full-vocab`, a stable model id/hash, and a
vocabulary size matching the returned logit vector. HTTP endpoints that expose
only `top_logprobs` do not meet this requirement.

The implemented local runtime path is a JSON-lines stdio sidecar. Set
`RACK_LLM_LLAMA_SIDECAR` to a command that reads one JSON object per line and
writes one JSON response per line, then use:

```racket
(require rack-llm/providers/llama-local-provider)

(define p
  (make-llama-local-provider
   #:model-path "/models/model.gguf"
   #:seed 42
   #:runtime 'stdio-sidecar))
```

Minimum operations:

- `load`: returns `ok`, `session`, `vocab_size`, and optional `model_id` /
  `model_hash`.
- `tokenize`: accepts `text`, returns `tokens`.
- `detokenize`: accepts `tokens`, returns `text`.
- `next_logits`: accepts `session`, `prompt`, and `prefix`; returns
  `vocab_size`, either `logits` or `logits_b64`, and timing/cache metadata.

`logits_b64` is big-endian float64 data. The optional integration test runs
with:

```bash
RACK_LLM_TEST_GGUF=/path/to/tiny.gguf \
RACK_LLM_LLAMA_SIDECAR='python sidecar.py' \
make test-llama-local
```

## OpenAI Compatibility

`make-openai-compat-provider` adapts the OpenAI Responses backend to Provider
v2, but it reports `truncated-top-k`. It is suitable for demos and weak
baselines where truncation is explicit. `require-exact-provider` rejects it for
synthetic exactness tests.

## Why Full-Vocab Logits Are Required

The Gumbel stream used for exact constrained sampling needs the probability mass
of every next-token branch. APIs that return only top log probabilities are
useful for demos and weak baselines, but they have already discarded unknown
mass. OpenAI Responses logprobs and HTTP llama.cpp top-probability endpoints
therefore run in compatibility or truncated mode unless a local runtime returns
the full vocabulary vector.

Release experiments should record `run-metadata` with provider name, provider
mode, model id/hash, grammar id, rule-set id, seed, and library version.
