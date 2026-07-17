# rack-llm

`rack-llm` is a compact Racket library for exact hard-constrained generation
and zero-label posterior-weighted selective generation. Its public surface is a
small DSL, a batched generation call, weak-model fitting, and an extensible
backend protocol.

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

(define answer
  (with-rules
   (seq (choice (lit " yes") (lit " no")) (repeat 0 1 (lit ".")))
   (positive (ere "yes"))
   (negative (ere "no"))))
(define compiled (compile-spec backend answer))

;; A weak model is fitted from label vectors only; official/gold labels are not
;; accepted by this API.
(define weak (fit-weak-model calibration-observations #:seed 0))
(define requests
  (for/list ([seed (in-range 8)])
    (generation-request
     compiled "Reply with yes or no:"
     #:max-attempts 100 #:max-model-draws 1000 #:weak-model weak
     #:temperature 0.7 #:max-tokens 3 #:seed seed #:deadline-ms 30000)))
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
| `(with-rules p rule ...)` | A nestable weak-rule scope. |
| `(positive (lit/ere ...))` | Positive weak observation. |
| `(negative (lit/ere ...))` | Negative weak observation. |

`observe-token-ids` returns an immutable vector in `{-1,0,+1}` in structural
rule order. `fit-weak-model` learns a polarity-constrained three-state latent
model without gold labels. Models are versioned through `save-weak-model` and
`load-weak-model`; clients persist their own ordered rule identities beside a
model.

`generate-batch` is the only generation entry point. Requests are independent,
results preserve input order, and the scheduler partitions them into fixed
physical cohorts. A backend admits only one active batch. Results expose status,
reason, output, posterior, latency, attempts, proposed tokens, model draws, and
CARS trie size. A `found` result is hard-valid by construction; rejected
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
  -> program.rkt + regex.rkt       DSL, continuation VM, weak observations
  -> weak.rkt                      zero-label posterior
  -> generate.rkt + cars.rkt       exact CARS and fixed-cohort scheduler
  -> model.rkt / backend.rkt       public provider protocol
  -> model-llama-cpp.rkt           llama.cpp implementation
```

Hard CARS targets the temperature-scaled model distribution conditioned on the
hard language. With terminal posterior `p(x)`, PWSG targets the same hard
distribution additionally weighted by `p(x)`. There is no top-k mask, scalar
generation path, or approximate fallback.

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
