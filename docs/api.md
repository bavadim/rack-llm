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
(model-close! model)    ; -> Void, idempotent
```

Tokenizer, provider, and logits interfaces are private runtime details.

## Programs

```racket
(lit text)
(rx pattern)
(pure value)
(seq programs)
(choice programs)
(repeat min-count max-count program)
(bind program continue)
(score score program)
(text max-tokens observers)

(rank score text)
(ban text)
(rank-rx score pattern)
(ban-rx pattern)
(weight samples specs)
```

These functions return immutable programs and text observers. `generate` compiles a program with
the model tokenizer internally:

```racket
(define program
  (choice (list (lit " yes")
                (lit " no"))))
```

`seq` and `choice` take lists of programs.

`rank` and `ban` are literal token-sequence observers. `rank-rx` and `ban-rx`
use regex search semantics over the generated text inside `text`.

Regex patterns use PCRE2 syntax. Consuming regular patterns use PCRE2's
restartable DFA over token pieces. Constructs whose meaning depends on a token
boundary, including lookaround, anchors, boundaries, atomic groups, `\\R`, and
`\\X`, are matched exactly by replaying the complete prefix. Backreferences,
capture-dependent conditionals, recursion, `\\K`, and `\\C` remain rejected.

## Generate

```racket
(generate model prompt program
          #:beta 1.0
          #:sampler (local-sampler #:lambda 0.5)
          #:temperature 0.7
          #:seed #f
          #:deadline-ms #f
          #:max-tokens 128)
```

Generation is exact over the model vocabulary at ambiguous token-level steps.
Guidance may fast-forward deterministic segments internally. `#:max-tokens`
bounds decoder transitions; it does not condition sampling on eventual regex
acceptance. A live but non-accepting prefix at that boundary returns
`not-found-budget`.
`#:deadline-ms` is a coarse guard between generation steps; it does not
interrupt one exact vocabulary or segment scoring pass.

The result contains generated text and token ids:

```racket
(generation-result-text result)
(generation-result-token-ids result)
```

Deterministic forced tokens are fast-forwarded without a provider logits
request or a second scoring pass. If any generated segment was forced,
`generation-result-lm-logprob` and `generation-result-total-score` are `#f`.

## Reusable CARS

```racket
(define generator
  (make-generator model prompt program
                  #:sampler (cars-sampler #:max-attempts 100
                                          #:max-trie-nodes #f)
                  #:beta 1.0
                  #:temperature 0.7
                  #:max-tokens 128
                  #:seed 0))

(generator-sample! generator #:deadline-ms 30000)
(generator-sample-n! generator 20 #:deadline-ms 30000)
(generator-close! generator)
```

`max-attempts` is required and applies to each requested result. Exhaustion
returns `not-found-attempts`; no rejected output is returned as an approximate
fallback. Prompt, model, program, temperature, beta and token horizon are fixed
for the generator because they define the CARS trie distribution.

The exact weighted target is
`Q_temperature(output, STOP) * exp((beta / temperature) * guidance-score)`.
Natural model EOG tokens stop before the horizon; after exactly `max-tokens`
content tokens a virtual STOP is forced. `bind` is supported by local sampling
and by hard CARS (`beta = 0`), but rejected by weighted CARS.

## Private Runtime

Tokenizer/provider state, logits views, guidance state, regex machines, and
sampling selection helpers are private implementation details. User code should
choose a model, define a program, and call `generate`.
