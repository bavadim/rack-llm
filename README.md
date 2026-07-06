# rack-llm

`rack-llm` is a small Racket library for controlling text generation with
closed languages, soft preferences, and hard vetoes.

```text
Guide[A] = string + value + log-score
```

Closed guides define the allowed language. `text` is the only open-world
segment and can be bounded with `#:max-tokens`. `rank` adds soft score, and
`ban` is a hard veto inside `text`. `text #:until` remains available for
post-hoc `check`, but production sampling currently reports
`unsupported-guide-for-sampling` for it.

## Use

```racket
#lang racket/base

(require rack-llm)

(define provider
  (make-mock-provider
   #:vocab '("Answer: " "yes" "no" "maybe")
   #:default-logits '#(0.0 0.0 0.1 10.0)))

(define guide
  (seq "Answer: " (select "yes" "no")))

(define result
  (generate provider "" guide))

(unless (check-result-ok? (check guide (generation-result-text result)))
  (error 'readme "generated text failed guide check"))

(displayln (generation-result-text result))
```

## API

```racket
lit rx seq select repeat text rank ban pure bind generate check
make-provider make-mock-provider
```

`generate` supports candidate policies:

```racket
'full-vocab          ; exact scan over all token ids
'allowed-only        ; exact small set from finite trie runtime, with fallback
'(top-k+watch 64)    ; approximate soft mode: top-K plus watched token ids
```

`top-k+watch` is approximate; use `full-vocab` or `allowed-only` when hard
coverage matters. Hot-path counters are available in
`generation-result-metrics`, including `candidate-count-total`,
`runtime-step-calls`, `check-calls-in-sampling`, `fast-forward-tokens`, and
`provider-session?`.

## llama.cpp

Full-vocabulary logits require a local sidecar process, not the normal
llama.cpp HTTP completion endpoint. The sidecar reads one JSON request per line
from stdin and writes one JSON response per line to stdout.

```racket
(require rack-llm
         rack-llm/llama-cpp)

(define provider
  (make-llama-cpp-provider
   #:model-path "model.gguf"
   #:command "./llama-logits-sidecar"))
```

Expected sidecar protocol:

```text
{"op":"load","model_path":"model.gguf","context_size":512,"threads":1,"seed":0}
-> {"ok":true,"vocab":["yes","no",...]}

{"op":"next_logits","prompt":"Question: ...","prefix":"yes"}
-> {"ok":true,"logits":[-1.2,-3.4,...]}

{"op":"start","prompt":"Question: ..."}
-> {"ok":true,"session_id":"optional"}

{"op":"next_logits"}
-> {"ok":true,"logits":[-1.2,-3.4,...]}

{"op":"commit","token_id":123}
-> {"ok":true}

{"op":"end"}
-> {"ok":true}
```

Providers may also implement the optional stateful session protocol:
`provider-start-session`, `provider-next-logits/session`,
`provider-commit-token!`, and `provider-end-session!`.

The response may use `logits_b64` instead of `logits`; it must encode
little-endian 64-bit floats for the full vocabulary.

## Examples

```racket
(seq "Answer: " (select "yes" "no"))
(select (rank 2 "approve") "reject" "review")
(text (rank 3 (rx #px"US[0-9]+")) (ban (rx #px"TODO")))
(bind (rx #px"[0-9]")
      (lambda (a)
        (lit (number->string (+ 1 (string->number a))))))
```

## Development

```bash
raco pkg install --auto
make ci
```

`make ci` compiles the small library modules and runs `tests/core-test.rkt`.

Current layout:

```text
core.rkt      data structures, pure, bind
guides.rkt    guide constructors and scoring annotations
runtime.rkt   check runtime and finite candidate enumeration
provider.rkt  provider contract and mock provider
sampling.rkt  generate
main.rkt      public re-export boundary
llama-cpp.rkt full-logits sidecar bridge
```

Provider modes are documented in `docs/provider.md`.
Logprob and sampling math are documented in `docs/sampling.md`.
Prefix runtime states are documented in `docs/runtime.md`.
Weighted observers are documented in `docs/weight.md`.
Trace and metrics are documented in `docs/trace.md`.

The sampler draws from adjusted logits:

```text
l'_t(v) = l_t(v) + guide_adjustment(v)

guide_adjustment(v) =
  -inf                                      if the guide transition is dead
  beta * (Delta guide-score + lambda * Delta potential) otherwise
```

For exact providers this pass scans the full vocabulary. It does not use top-k
shortlists; if `#:deadline-ms` expires during the full-vocabulary pass,
`generate` returns `error-budget`.

For local runtime checks, `make bench` writes CSV files under `bench/results/`.

The repository intentionally keeps the core library, the llama.cpp bridge, this
README, and focused tests.
