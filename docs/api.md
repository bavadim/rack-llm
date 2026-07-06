# rack-llm API v1

`rack-llm` exposes a compact guide DSL for controlled text generation.

```text
Guide[A] = weighted set of (string, value, log-score)
```

Hard guidance is `0/-inf` scoring over a closed language. Soft guidance adds
finite log-score. `text` is the only open-world form.

## Core Data

The implementation is split into small modules:

```text
core.rkt      data structures, pure, bind
guides.rkt    guide constructors and scoring annotations
runtime.rkt   check runtime and finite candidate enumeration
provider.rkt  provider contract, tokenization, mock provider
sampling.rkt  generate
main.rkt      public re-export boundary
llama-cpp.rkt full-logits sidecar bridge
```

| Name | Meaning |
|---|---|
| `Guide[A]` | A string language with a returned value and guide score. |
| `Watch` | Open-text observer used by derived scoring forms. |
| `Ranked` | Delayed soft score annotation from `rank`; does not open the world. |
| `Banned` | Hard veto annotation from `ban` for open text. |
| `Provider` | Vocabulary plus `(prompt prefix) -> logits` callback. |
| `GenerationResult` | Status, reason, generated text, value, LM score, guide score, metrics. |
| `CheckResult` | Check status, parsed value, guide score. |
| `rt-state` | Prefix runtime state for generation viability. |

Exported predicates: `guide?`, `watch?`, `ranked?`, `banned?`, `provider?`,
`generation-result?`, `check-result?`, `found?`, `not-found?`,
`hard-failure?`, `low-score?`, `provider-error?`.

Log-score helpers:

| Function | Semantics |
|---|---|
| `log-score-add` | Add scores, preserving `-inf.0` as hard failure. |
| `log-score-dead?` | True for impossible score `-inf.0`. |
| `log-score>?` | Compare two log-scores. |

## Closed-World Guides

| Function | Signature | Semantics |
|---|---|---|
| `lit` | `(lit s) -> Guide[Void]` | Match exactly `s`. |
| `rx` | `(rx pattern) -> Guide[String]` | Match a full regular-expression segment. |
| `seq` | `(seq g ...) -> Guide[A]` | Concatenate guides. |
| `select` | `(select g ...) -> Guide[A]` | Choose one closed alternative. |
| `repeat` | `(repeat min max g) -> Guide[(Listof A)]` | Finite bounded repetition. |

Closed guides reject strings outside their language with `-inf`.

## Open-World Text

| Function | Signature | Semantics |
|---|---|---|
| `text` | `(text #:max-tokens n #:until end watch ...) -> Guide[String]` | Generate arbitrary text within a token budget. |

`text` is the only open-world segment. A bare `rank` does not allow arbitrary
text; it must be interpreted by a parent guide.

## Scoring

| Function | Signature | Semantics |
|---|---|---|
| `rank` | `(rank w expr) -> Ranked` | Add finite score `w` when `expr` matches. |
| `ban` | `(ban expr) -> Banned` | Hard veto when `expr` matches in `text`. |
| `weight` | `(weight #:data samples ranked-watch ...) -> Watch` | Learn a weighted watcher ensemble with EM. |

In closed contexts such as `select`, `rank` scores a closed alternative. In
`text`, `rank` is a watcher over open text.

## Values

| Function | Signature | Semantics |
|---|---|---|
| `pure` | `(pure x) -> Guide[A]` | Empty guide returning `x`. |
| `bind` | `(bind guide f) -> Guide[B]` | Pass the parsed value into ordinary Racket code and continue with the returned guide. |

`bind` is the replacement for old capture/env-map operators. The continuation
is ordinary Racket code that must return a finite guide for the next segment;
unbounded DSL recursion is intentionally not part of v1.

## Execution

| Function | Signature | Semantics |
|---|---|---|
| `check` | `(check guide text) -> CheckResult` | Parse text against a guide and return status/value/score. |
| `guide-init` | `(guide-init guide) -> rt-state` | Initialize prefix runtime state. |
| `guide-step` | `(guide-step state token) -> rt-state` | Advance runtime state by one token string. |
| `guide-finish` | `(guide-finish state) -> rt-state` | Finalize a prefix state. |
| `finite-candidates` | `(finite-candidates guide) -> (or/c list? #f)` | Enumerate finite guides; `#f` for open/infinite guides. |
| `fast-forward-state` | `(fast-forward-state state provider prompt prefix #:score? score?) -> values` | Advance deterministic literal state without sampling a token choice. |
| `dead?` | `(dead? state) -> boolean` | True when a prefix cannot become valid. |
| `done?` | `(done? state) -> boolean` | True when a prefix is already accepted. |
| `state-score` | `(state-score state) -> real` | Current guide score. |
| `state-potential` | `(state-potential state) -> real` | Current shaping potential. |
| `state-value` | `(state-value state) -> any` | Current parsed value when done. |
| `state-trace` | `(state-trace state) -> list` | Debug trace for runtime transitions. |
| `generate-stream` | `(generate-stream provider prompt guide ...) -> stream` | Lazy stream of generation candidates. |
| `generate` | `(generate provider prompt guide #:samples n #:keep-best? keep? #:unique unique #:return-policy policy ...) -> GenerationResult or list` | Generate one or more candidates using `generate-stream`; best-of returns max total score. |
| `min-guide-score` | `(min-guide-score threshold) -> policy` | Return `not-found-low-score` when guide score is below threshold. |
| `min-total-score` | `(min-total-score threshold) -> policy` | Return `not-found-low-score` when total score is below threshold. |
| `log-softmax` | `(log-softmax logits) -> vector` | Convert logits to log-probabilities. |
| `sequence-logprob` | `(sequence-logprob provider prompt text) -> real` | Sum model log-probability for tokenized text. |
| `sample-id` | `(sample-id adjusted-logits rng temperature) -> token-id` | Seedable Gumbel-Max sampling helper. |

Runtime state struct bindings exported by Racket: `rt-state`, `rt-state?`,
`rt-state-guide`, `rt-state-text`, `rt-state-status`, `rt-state-score`,
`rt-state-potential`, `rt-state-value`, `rt-state-trace`,
`struct:rt-state`.

Result accessors:

```racket
generation-result-text
generation-result-value
generation-result-status
generation-result-reason
generation-result-lm-logprob
generation-result-lm-score
generation-result-guide-score
generation-result-total-score
generation-result-hard-ok?
generation-result-low-score?
generation-result-steps
generation-result-attempts
generation-result-generated-tokens
generation-result-latency-ms
generation-result-trace
generation-result-metrics
generation-result-ok?
check-result-value
check-result-guide-score
check-result-hard-ok?
check-result-trace
check-result-failures
check-result-matched-watchers
check-result-metrics
check-result-ok?
```

Struct bindings exported by Racket: `generation-result`,
`struct:generation-result`, `check-result`, `struct:check-result`.

## Providers

| Function | Signature | Semantics |
|---|---|---|
| `make-provider` | `(make-provider #:vocab vocab #:next-logits f #:tokenize tok #:detokenize detok) -> Provider` | Construct a provider from token strings, logits, and optional tokenizer callbacks. |
| `make-mock-provider` | `(make-mock-provider #:vocab vocab #:default-logits logits ...) -> Provider` | Deterministic provider for tests and examples. |
| `provider-vocab-size` | `(provider-vocab-size provider) -> exact-nonnegative-integer?` | Fast vocabulary size accessor. |
| `provider-token-ref` | `(provider-token-ref provider id) -> string` | Fast `token-id -> token string` accessor backed by a vector. |
| `provider-vocab-vector` | `(provider-vocab-vector provider) -> vector` | Internal hot-path vocabulary vector. |
| `provider-tokenize` | `(provider-tokenize provider) -> procedure or #f` | Access the provider tokenizer callback. |
| `provider-detokenize` | `(provider-detokenize provider) -> procedure or #f` | Access the provider detokenizer callback. |
| `provider-session-supported?` | `(provider-session-supported? provider) -> boolean` | True when the provider implements the optional stateful session protocol. |
| `provider-start-session` | `(provider-start-session provider) -> procedure or #f` | Access the session start callback. |
| `provider-next-logits/session` | `(provider-next-logits/session provider) -> procedure or #f` | Access the session logits callback. |
| `provider-commit-token!` | `(provider-commit-token! provider) -> procedure or #f` | Access the session token commit callback. |
| `provider-end-session!` | `(provider-end-session! provider) -> procedure or #f` | Access the session cleanup callback. |
| `tokenize` | `(tokenize provider text) -> token-id-list` | Tokenize text through the provider tokenizer, or toy longest-match fallback. |
| `detokenize` | `(detokenize provider ids) -> string` | Decode provider token ids to text. |

Real model providers should supply tokenizer callbacks. The fallback tokenizer is
for tests and small hand-written vocabularies only.

Provider accessors: `provider-vocab`, `provider-next-logits`,
`provider-mode`, `provider-metadata`.

`rack-llm/llama-cpp` provides a separate full-logits sidecar bridge:

```racket
make-llama-cpp-provider
make-llama-cpp-sidecar
close-llama-cpp-sidecar
decode-logits
```

Trace and metrics schema are documented in `docs/trace.md`.

## Removed

Legacy capture/rule/resampling operators are removed and must not be exported.
