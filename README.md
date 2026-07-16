# rack-llm

`rack-llm` is a token-native Racket library for exact hard-constrained and
calibrated programmatic weak sequence generation. It combines an immutable
sequence program, a stateful `llama.cpp` model session, and CARS rejection
sampling.

The root package is the library. [`experiments/`](experiments/) contains
research and paper-reproduction artifacts; its Python dependencies, datasets,
and runners are not required to install or use `rack-llm`.

## Install

The current native build targets Linux shared libraries. It is tested on Ubuntu
24.04 x86-64 with Racket 9.1.

Install Racket, a C compiler, GNU Make, and PCRE2 development headers, then
install from a clone:

```sh
sudo apt-get install racket build-essential libpcre2-dev
git clone https://github.com/bavadim/rack-llm.git
cd rack-llm
make install
make unit-ci
```

`make install` builds the mandatory native PCRE2 facade before linking the
Racket package. `RACK_LLM_REGEX_NATIVE_LIB` may point to an alternative build.

### llama.cpp model backend

`llama-cpp-model` is the only public model backend. It needs a local
`llama.cpp` shared-library build and a local GGUF model with at least one EOG
token. The shim is tested against llama.cpp commit
`683f0c72e5b3c07fab90bfd9ec2ce8661d624228`.

```sh
git clone https://github.com/ggml-org/llama.cpp.git
export LLAMA_CPP_DIR=/absolute/path/to/llama.cpp
git -C "$LLAMA_CPP_DIR" checkout 683f0c72e5b3c07fab90bfd9ec2ce8661d624228

cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_DIR/build-rack-llm" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_CUDA=OFF
cmake --build "$LLAMA_CPP_DIR/build-rack-llm" -j

make native-llama LLAMA_CPP_DIR="$LLAMA_CPP_DIR"
export RACK_LLM_GGUF_MODEL=/absolute/path/to/model.gguf
make examples LLAMA_CPP_DIR="$LLAMA_CPP_DIR"
```

Use `-DGGML_CUDA=ON` for a CUDA build. In Racket, `#:gpu-layers 0` keeps model
weights on CPU and `-1` requests full offload. The backend passes prompts as raw
text; it does not apply the GGUF chat template. `#:context-size` must fit the
tokenized prompt plus the generation horizon.

`RACK_LLM_LLAMA_NATIVE_LIB` or `llama-cpp-model`'s `#:native-lib` can select an
alternative shim.

## Examples

All examples require only the public library facade and backend. Complete
executable files live in [`examples/`](examples/).

### Exact finite choice

```racket
(require rack-llm
         rack-llm/model-llama-cpp)

(define model
  (llama-cpp-model #:model-path (getenv "RACK_LLM_GGUF_MODEL")
                   #:context-size 192
                   #:gpu-layers -1))
(define compiled
  (compile-spec model (choice (list (lit " yes") (lit " no")))))

(define result
  (generate compiled
            "Reply with exactly yes or no:"
            #:sampler (cars-sampler #:max-attempts 50)
            #:max-tokens 2
            #:seed 7))

(unless (eq? (generation-result-status result) 'found)
  (error 'generate "~a" (generation-result-reason result)))
(displayln (generation-result-text result))

(compiled-spec-close! compiled)
(model-close! model)
```

This samples exactly from the temperature-scaled model distribution restricted
to the two literal sequences. See
[`examples/hard-choice.rkt`](examples/hard-choice.rkt).

### Hard regex, scoped ban, and reusable sampling

```racket
(define spec
  (control
   (ere " status=(approved|rejected|TODO)")
   (ban (lit "TODO"))))
(define compiled (compile-spec model spec))
(define generator
  (make-generator
   compiled
   "Return one status: approved or rejected."
   #:sampler (cars-sampler #:max-attempts 100)
   #:max-tokens 8
   #:seed 11))

(define results (generator-sample-n! generator 3 #:deadline-ms 30000))

(generator-close! generator)
(compiled-spec-close! compiled)
```

The generator reuses its RNG, fractional CARS trie, and evaluated terminals
between samples. `TODO` has zero hard mass. See
[`examples/hard-ban-batch.rkt`](examples/hard-ban-batch.rkt).

### Calibrated soft constraints

```racket
(require racket/list)

(define spec
  (control
   (text 12)
   (prefer (lit "clear"))
   (prefer (lit "answer"))
   (avoid (lit "sorry"))
   (avoid (lit "unknown"))
   (ban (lit "private key"))))
(define compiled (compile-spec model spec))

(define calibration-corpus
  (append
   (make-list 80 " clear answer")
   (make-list 30 " clear")
   (make-list 25 " answer")
   (make-list 70 " sorry unknown")
   (make-list 20 " sorry")
   (make-list 18 " unknown")))
(define weak-model
  (fit-weak-model (observe-many compiled calibration-corpus)))

(define result
  (generate
   compiled
   "Give a short direct answer to: What is 2+2?"
   #:sampler (cars-sampler #:max-attempts 100
                           #:weak-model weak-model)
   #:max-tokens 12
   #:seed 13))
```

The corpus is deliberately synthetic; production calibration should use a
representative candidate corpus for the same tokenizer and program shape. A fit
fails closed unless at least three rule columns are informative and
non-duplicate. See [`examples/soft-pwsg.rkt`](examples/soft-pwsg.rkt).

## Program DSL

| Form | Semantics |
| --- | --- |
| `(lit string)` | Exact token sequence produced by the model tokenizer. |
| `(ere pattern)` | Portable case-sensitive regex with full-match guide semantics. |
| `(rx pattern)` | Broader PCRE2 DFA-compatible hard-only regex. |
| `(choice programs)` | Unordered union; every accepting parse contributes weak matches. |
| `(seq programs)` | Ordered, non-empty concatenation. |
| `(repeat min max program)` | Bounded repetition; the child must not accept empty input. |
| `(text max-tokens)` | Any `0..max-tokens` content tokens; only valid in tail position and never inside `repeat`. |
| `(control program rules ...)` | Scopes `prefer`, `avoid`, and `ban` over one program occurrence. |
| `(prefer (lit/ere ...))` | Weak `+1` label on a scoped search match, otherwise abstain. |
| `(avoid (lit/ere ...))` | Weak `-1` label on a scoped search match, otherwise abstain. |
| `(ban (lit/ere ...))` | Hard scoped search veto; it is not part of the weak label vector. |
| `(validate-pwsg program)` | Returns profile diagnostics; an empty list means compatible. |

The ERE profile supports literals, `.`, alternation, groups, character classes,
`* + ? {m} {m,n} {m,}`, `^`, `$`, and escaped metacharacters/newlines. It does
not support flags, shorthand classes, lazy quantifiers, lookaround,
backreferences, or other PCRE extensions. As guides, `ere` and `rx` use
full-match semantics; control rules search within their scope.

`compile-spec` checks layout restrictions but intentionally permits hard-only
`rx`. The full PWSG profile is checked by `validate-pwsg`, observation, and
construction of a generator with a weak model. Repeated control occurrences
aggregate each rule by any-match; inactive and nonaccepting branches abstain.
Prefix-overlapping alternatives are preserved through `seq` and `repeat`, so
equivalent reordering of `choice` branches does not change the hard language or
weak observation.

## Public API

The stable facade is `(require rack-llm)`. Model construction is separately
provided by `(require rack-llm/model-llama-cpp)`.
`Model`, `CompiledSpec`, `WeakObservation`, `WeakModel`, `Sampler`, and
`Generator` are public opaque types.

### Models and compilation

```racket
(llama-cpp-model #:model-path path
                 #:native-lib #f
                 #:context-size 512
                 #:threads 1
                 #:gpu-layers -1)
(model-metadata model)
(model-close! model)

(compile-spec model program)
(compiled-spec-close! compiled)
```

The first compilation for a model enumerates its vocabulary, creates the native
regex vocabulary, and fingerprints the tokenizer. Later specifications reuse
that model compilation context.

### Observation and weak model

```racket
(observe compiled string-or-generation-result #:trace? #f)
(observe-token-ids compiled token-ids #:trace? #f)
(observe-many compiled candidates #:trace? #f)

(fit-weak-model observations
  #:max-iterations 200
  #:tolerance 1e-7
  #:pseudocount 1.0
  #:restarts 8
  #:seed 0)
(weak-posterior weak-model observation)
(save-weak-model weak-model path)
(load-weak-model path)
```

`observe` requires a hard-valid string that round-trips exactly through the
tokenizer. `observe-token-ids` is the dataset-safe alternative. Trace mode
stores control-scope token spans; these are not exact regex-match spans.

Public observation accessors are:

```text
weak-observation? / labels / rule-paths / polarities / scope-spans
weak-observation-schema-fingerprint / weak-observation-spec-fingerprint
token-span? / token-span-start-token / token-span-end-token
```

Public weak-model accessors are:

```text
weak-model? / weak-model-fingerprint / weak-model-schema-fingerprint
weak-model-diagnostics
```

The fitted model is a constrained two-component product-Bernoulli model. Each
rule learns `P(fire | bad)` and `P(fire | good)` with its declared polarity.
Non-fire is an observed abstention, not the opposite vote. Fits with too few
informative rules, duplicate columns, non-convergence, or collapse are errors.
Versioned JSON persistence checks structural and model fingerprints.
The current persistence format is v3; v2 models are rejected because weak
observations now merge all accepting parses and must be refitted.

### Sampling

```racket
(cars-sampler #:max-attempts positive-integer
              #:max-trie-nodes #f
              #:weak-model #f
              #:min-posterior 0.0
              #:ignore-weak? #f)

(make-generator compiled prompt
                #:sampler sampler
                #:temperature 0.7
                #:max-tokens 128
                #:seed #f)
(generator-sample! generator #:deadline-ms #f)
(generator-sample-n! generator count #:deadline-ms #f)
(generator-close! generator)

(generate compiled prompt
          #:sampler sampler
          #:temperature 0.7
          #:max-tokens 128
          #:seed #f
          #:deadline-ms #f)
```

`#:min-posterior` must be in `[0,1]` and a nonzero value requires a weak model.
If the program contains `prefer` or `avoid`, omitting `#:weak-model` is an
error (`weak-model-required`). Use `#:ignore-weak? #t` for an intentional
hard-only baseline; it is mutually exclusive with `#:weak-model`. Programs
containing only hard rules, including `ban`, need no weak model.
The generator horizon is distinct from `(text n)`. Deadlines are checked
between complete attempts, so one attempt may overrun; in
`generator-sample-n!` the deadline applies independently to every sample.
Generators are stateful and cannot be sampled concurrently or reentrantly.

`generate` creates and closes one temporary generator. It does not close the
compiled specification or model.

### Results

`generation-result` fields are:

```text
status reason token-ids text lm-logprob target-log-weight hard-ok?
distribution-guarantee latency-ms tokenizer-fingerprint weak metrics
```

Statuses are `found`, `not-found-attempt-budget`, `not-found-time-budget`,
`not-found-support`, `backend-error`, and `internal-invalid`. Successful
guarantees are `exact-hard` or `exact-pwsg`; failures use `no-sample`, empty
text/ids, and no fallback candidate.

`weak-result` exposes:

```text
observation posterior min-posterior terminal-mass terminal-envelope
acceptance-probability acceptance-draw model-fingerprint schema-fingerprint
```

`generation-metrics` exposes:

```text
attempts rejected-attempts hard-invalid-attempts hard-proposals
threshold-rejections posterior-rejections weak-rejections weak-evaluations
weak-cache-hits proposed-tokens llm-calls vocab-size trie-nodes
root-envelope trie-frozen? weak-policy
```

`weak-policy` is `not-present`, `applied`, or `ignored-explicitly`, including
on failed sampling results.

The three transparent result structures export their constructors, predicates,
and field accessors.

## Architecture and guarantees

```text
immutable Program AST
        |
        v
compile-spec -----> tokenizer/spec/schema fingerprints
        |
        +----> token-native hard Guidance + scoped weak rules
                         |
prompt --> Provider session per attempt --> logits
                         |                    |
                         +--> hard domain ----+--> fractional CARS trie
                                                    |
hard-valid terminal --> WeakObservation --> posterior/threshold mass
                                                    |
                                             generation-result
```

Guidance state belongs to one proposal. Hard programs and bans restrict token
domains online. `prefer` and `avoid` are evaluated only at a hard-valid
terminal. Each attempt starts or resets a provider session and always ends it;
a reusable generator keeps only prompt ids, RNG, its fractional trie, and
immutable terminal evaluations.

For model distribution `Q_T`, hard acceptance `H`, posterior `p`, and threshold
`tau`, the exact targets are:

```text
hard: Q_T(x) H(x)
PWSG: Q_T(x) H(x) p(x) 1[p(x) >= tau]
```

CARS stores an upper envelope in a reusable trie. Unknown terminal mass is one,
hard-invalid mass is zero, and evaluated weak mass is either its posterior or
zero below the threshold. Acceptance uses `new-mass / old-envelope`; the trie
is tightened only after the draw. A stochastic posterior rejection therefore
does not delete a valid terminal.

Temperature changes only `Q_T`. There is no top-k approximation, manual score,
local potential, or approximate fallback.

The native ownership chain is `regex state → regex → vocabulary`. Token domains
use compact all/only/except representations. The llama.cpp shim scans the full
vocabulary and sparse trie child masses natively instead of crossing FFI once
per token.

Resource ownership is explicit:

```text
llama-cpp-model
  -> compile-spec
    -> make-generator / sample
    -> generator-close!
  -> compiled-spec-close!
-> model-close!
```

Both compiled specifications and generators lease the model. `model-close!`
fails while either remains open.
