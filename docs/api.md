# API

## Specification

```racket
(lit text)
(rx pcre-pattern)
(ere portable-pattern)
(seq programs)
(choice programs)
(repeat min max program)
(text max-tokens)
(control program rule ...)
(prefer (lit-or-ere pattern))
(avoid  (lit-or-ere pattern))
(ban    (lit-or-ere pattern))
(validate-pwsg program)
```

`text` accepts zero through `max-tokens` and is restricted to tail position.
`ere` is fullmatch as a guide and search as a rule. `rx` is a hard-only
extension. `validate-pwsg` returns diagnostics; an empty list means compatible.

## Calibration

```racket
(define compiled (compile-spec model spec))
(observe compiled text-or-generation-result #:trace? #f)
(observe-token-ids compiled ids #:trace? #f)
(observe-many compiled candidates #:trace? #f)
(fit-weak-model observations
  #:max-iterations 200 #:tolerance 1e-7
  #:pseudocount 1.0 #:restarts 8 #:seed 0)
(weak-posterior weak-model observation)
(save-weak-model weak-model path)
(load-weak-model path)
```

Compilation creates the regex vocabulary once. `observe` rejects text outside
the hard language and requires tokenizer round-trip; `observe-token-ids` is the
dataset API. Trace mode adds scope spans; the default stores labels only.

## Generation

```racket
(define sampler
  (cars-sampler #:max-attempts 100
                #:max-trie-nodes #f
                #:weak-model weak-model-or-#f
                #:min-posterior 0.0))

(define generator
  (make-generator compiled prompt
                  #:sampler sampler
                  #:temperature 0.7
                  #:max-tokens 128
                  #:seed #f))

(generator-sample! generator #:deadline-ms #f)
(generator-sample-n! generator count #:deadline-ms #f)
(generator-close! generator)
(compiled-spec-close! compiled)
```

Runtime statuses are `found`, `not-found-attempt-budget`,
`not-found-time-budget`, `not-found-support`, `backend-error`, and
`internal-invalid`. Invalid profiles and model/schema mismatches fail while the
generator is created.
