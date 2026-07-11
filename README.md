# rack-llm

`rack-llm` is a typed token-native core for controlled generation.

The public model is:

```text
Model + prompt text + program -> generation-result
```

Tokenizer, provider, and logits state are private runtime details supplied by a
model implementation.

## Public API

Core API:

```racket
(require rack-llm)
```

Model implementation:

```racket
(require rack-llm/model-llama-cpp)
```

A model is passed directly to `generate`:

```racket
(define m
  (llama-cpp-model
   #:model-path "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"))
```

Programs are immutable descriptions. `generate` compiles them with the model
tokenizer internally:

```racket
(define f
  (choice (list (lit " yes")
                (lit " no"))))

(define r
  (generate m
            "Reply yes or no:"
            f))

(generation-result-text r)
```

## Programs

Atomic programs:

```text
lit   exact token sequence
rx    token-level regex fullmatch
pure  accepting value without consuming tokens
text  open generation for a fixed token budget
```

Combinators:

```text
seq     ordered composition
choice  alternatives from a list of programs
repeat  bounded repetition
bind    dependent continuation
```

Soft constraints:

```text
score   reward wrapper
rank    observer that rewards a token sequence inside text
ban     observer that rejects a token sequence inside text
rank-rx observer that rewards a regex search match inside text
ban-rx  observer that rejects a regex search match inside text
weight  learned weighted observer from labeled string features
```

Regex patterns use PCRE2 syntax. Consuming regular patterns use restartable DFA
matching over token pieces; context-sensitive constructs such as lookaround,
boundaries, atomic groups, `\\R`, and `\\X` use exact full-prefix replay.
Backreferences and the remaining unsupported constructs are rejected when the
program is built.

The default local sampler combines model logits and guidance deltas as:

```text
lm-logit + beta * (delta-score + lambda * delta-potential)
```

For exact constrained sampling, use CARS:

```racket
(define g
  (make-generator m "Reply yes or no:" f
                  #:sampler (cars-sampler #:max-attempts 100)
                  #:beta 0.0))
(define samples (generator-sample-n! g 10))
(generator-close! g)
```

CARS samples from the temperature-adjusted model conditioned on the hard
language. With `beta > 0`, completed outputs are additionally weighted by
`exp((beta / temperature) * guidance-score)`. Its fractional envelope trie is
reused across calls to the same generator.

## Modules

```text
main.rkt              public facade: API types, builders, generate
private/logits.rkt    logits view abstraction for provider internals
private/model.rkt     tokenizer/provider/model runtime objects
private/guidance.rkt  guidance runtime state machines and token selection
private/regex.rkt     typed PCRE2 DFA/token transition facade
private/sampling.rkt  Gumbel sampling math for scored candidates
private/cars.rkt      persistent fractional-envelope CARS trie
model-llama-cpp.rkt   Qwen GGUF model implementation through llama.cpp
```

There is no compatibility layer for the old guide/runtime API, no mock provider
in the library, and no public `make-*` constructors.

## E2E Scenarios

Executable public API scenarios live in `tests/e2e-real-test.rkt` and run
against the real Qwen model. They cover finite hard choices, regex hard
constraints, soft open text, and dependent `bind` composition.

The core API boundary is intentionally narrow. Exact full-vocabulary soft
decoding is measured against the native GGUF backend.
