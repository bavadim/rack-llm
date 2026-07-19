# rack-llm

`rack-llm` is a compact Racket library for exact hard-constrained generation
and zero-label posterior-weighted generation. Its public surface is a small
DSL, EM calibration of noisy rules, one batched generation call, and an
extensible backend protocol.

The production Racket runtime is intentionally capped at 1500 physical lines.
`tests/loc-test.rkt` enforces the cap over `main.rkt`, `backend.rkt`,
`model-llama-cpp.rkt`, and `private/*.rkt`. Tests and the paper experiments are
clients, not part of the runtime.

## Install

The native build targets Linux and is tested with Racket 9.1.

```sh
sudo apt-get install racket build-essential libpcre2-dev
make install
make unit-ci
```

The llama.cpp shim is pinned to commit
`683f0c72e5b3c07fab90bfd9ec2ce8661d624228`:

```sh
git clone https://github.com/ggml-org/llama.cpp.git
export LLAMA_CPP_DIR=/absolute/path/to/llama.cpp
git -C "$LLAMA_CPP_DIR" checkout 683f0c72e5b3c07fab90bfd9ec2ce8661d624228
cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_DIR/build-rack-llm" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_CUDA=ON
cmake --build "$LLAMA_CPP_DIR/build-rack-llm" -j
make native-llama LLAMA_CPP_DIR="$LLAMA_CPP_DIR"
```

## DSL and generation

```racket
(require rack-llm)

(define backend
  (llama-cpp-backend
   #:model-path (getenv "RACK_LLM_GGUF_MODEL")
   #:cohort-width 8 #:context-per-lane 256 #:gpu-layers -1))

(define quality-rules
  (rule-set
   "reply-quality@1"
   (positive "explicit-yes" (ere "(^| )yes([^A-Za-z]|$)"))
   (positive "clear"        (ere "clear"))
   (negative "explicit-no"  (ere "(^| )no([^A-Za-z]|$)"))
   (negative "uncertain"    (ere "(maybe|unknown)"))))

;; The strings are unlabelled examples from the target population.  EM learns
;; rule reliabilities and conflicts; this API cannot accept gold labels.
(define calibration
  (fit-calibration quality-rules real-reply-strings #:seed 0))
(define compiled
  (compile-spec backend (with-rules (text 32) quality-rules)))
(define guided
  (attach-calibration compiled calibration #:good 20.0 #:bad 1.0))
(define requests
  (for/list ([seed (in-range 8)])
    (generation-request
     guided "Reply clearly:"
     #:max-attempts 100 #:max-model-draws 1000
     #:temperature 0.7 #:max-tokens 32 #:seed seed #:deadline-ms 30000)))
(define results (generate-batch requests))
(backend-close! backend)
```

The forms are:

| Form | Meaning |
| --- | --- |
| `(lit string)` | Exact token sequence. |
| `(ere pattern)` | Portable case-sensitive ERE, matched against the complete hard span. |
| `(seq p ...)` | Non-empty concatenation. |
| `(choice p ...)` | Non-empty union. |
| `(repeat min max p)` | Bounded repetition of a consuming program. |
| `(text max-tokens)` | Arbitrary tail content up to the token bound. |
| `(rule-set "schema@version" rule ...)` | Ordered logical rule schema. |
| `(positive "rule-id" (lit/ere ...))` | Positive noisy observation. |
| `(negative "rule-id" (lit/ere ...))` | Negative noisy observation. |
| `(with-rules hard rule-set)` | Attach whole-answer rules to a hard program. |

For fixed rules, `(fit-calibration rules strings)` is the short path. For
parameterized tasks, compile each task with the same schema ID, ordered rule
IDs, and polarities; collect schema-bound values with `observe` or
`observe-token-ids`; then call `(fit-calibration observations)`. Concrete
literal/ERE parameters may vary between tasks and are deliberately excluded
from the schema fingerprint. Reordering a rule, changing its polarity, or
attaching a calibration from another schema fails closed.

The polarity-constrained EM model uses labels in `{-1,0,+1}` and requires no
gold outcomes. Constant and exact-duplicate columns are projected out
deterministically. `calibration-diagnostics` reports learned fire-versus-
abstain log-likelihood weights by stable rule ID and explains every dropped
column. It is a latent-class conditional-independence model; pairwise
correlation remains a diagnostic and is not silently modeled as extra
independent evidence. `save-calibration` and `load-calibration` persist the
schema, projection, model parameters, diagnostics, and fingerprint in one
versioned artifact.

A compiled program is hard-only until `attach-calibration` returns a guided
copy. The optional policy weights good and bad latent classes separately. For
posterior `r(x)`, CARS receives terminal mass

```text
(b_good r(x) + b_bad (1-r(x))) / max(b_good, b_bad).
```

The default `(good=1, bad=0)` is selective posterior weighting; positive bad
mass, such as `(20,1)`, downweights rather than removes uncertain support.
Only a hard rule can make a string impossible.

`generate-batch` is the only generation entry point. Requests are independent,
results preserve input order, and the scheduler partitions them into fixed
physical cohorts. A backend admits only one active batch. Results expose status,
reason, output, weak posterior, terminal mass, calibration fingerprint,
latency, attempts, proposed tokens, model draws, and CARS trie size. A `found`
result is hard-valid by construction; rejected
attempts are `attempts - 1` for `found` and `attempts` otherwise. Failure returns
no fallback candidate.

## Backend protocol

Custom backends require `rack-llm/backend` and construct:

- a tokenizer (`make-tokenizer`) with a required stable fingerprint;
- a fixed-cohort provider (`make-provider`);
- a backend (`make-backend`).

The provider owns model sessions, KV/recurrent state, logits, and physical lane
IDs. The frontend sends sparse factor requests and full-width token commits.
Unused or completed lanes receive filler EOG tokens; lanes are not migrated or
refilled. Sampling occurs in the backend, so vocabulary-sized logits do not
cross the Racket boundary.

The extension module exports only these constructors, factor-request accessors,
the `factor-selection` constructor, and token-domain accessors. Tokenizer
internals and RNG state remain frontend-owned.

## Architecture

```text
main.rkt
  -> program.rkt + regex.rkt       hard VM, rule schemas and observations
  -> weak.rkt                      schema-bound zero-label EM calibration
  -> generate.rkt + cars.rkt       exact CARS and fixed-cohort scheduler
  -> model.rkt / backend.rkt       public provider protocol
  -> model-llama-cpp.rkt           llama.cpp implementation
```

Hard CARS targets the temperature-scaled backend distribution conditioned on
the hard language. Guided CARS targets that distribution additionally weighted
by the affine terminal utility above; normalization to mass at most one changes
only the global partition function. Within one weak-rule signature, the base
model probability ratios are preserved exactly. There is no prompt steering,
top-k mask, scalar generation path, or approximate fallback.

The fixed-cohort replay matrix checks that changing neighbouring lanes cannot
change a replayed lane inside the same CPU or CUDA execution profile:

```sh
make native-conformance LLAMA_CPP_DIR="$LLAMA_CPP_DIR"
make fixed-cohort-model-matrix LLAMA_CPP_DIR="$LLAMA_CPP_DIR" \
  RACK_LLM_PHI_MODEL=/path/to/phi.gguf \
  RACK_LLM_QWEN35_MODEL=/path/to/qwen3.5.gguf
```

The scientific client and its frozen execution protocol live in
[`experiments/`](experiments/).
