# API

## Specification

```racket
(lit text)
(rx pcre-pattern)
(ere portable-pattern)
(pure value)
(seq programs)
(choice programs)
(repeat min max program)
(bind program continue)
(text max-tokens)
(control program rule ...)
(prefer (lit-or-ere pattern))
(avoid  (lit-or-ere pattern))
(ban    (lit-or-ere pattern))
(pwsg-compatible? program)
```

`text` accepts zero through `max-tokens` and is restricted to tail position.
`ere` is fullmatch as a guide and search as a rule. `rx`, `pure`, and `bind` are
hard-only extensions.

## Calibration

```racket
(observe model spec text-or-generation-result)
(fit-weak-model observations
  #:max-iterations 200 #:tolerance 1e-7
  #:pseudocount 1.0 #:restarts 8 #:seed 0)
(weak-posterior weak-model observation)
(save-weak-model weak-model path)
(load-weak-model path)
```

`observe` rejects text outside the hard language. The returned observation
contains signed labels, structural paths, scope token spans, and schema/spec
fingerprints.

## Generation

```racket
(define sampler
  (cars-sampler #:max-attempts 100
                #:max-trie-nodes #f
                #:weak-model weak-model-or-#f
                #:min-posterior 0.0))

(define generator
  (make-generator model prompt spec
                  #:sampler sampler
                  #:temperature 0.7
                  #:max-tokens 128
                  #:seed #f))

(generator-sample! generator #:deadline-ms #f)
(generator-sample-n! generator count #:deadline-ms #f)
(generator-close! generator)
```

Runtime statuses are `found`, `not-found-attempt-budget`,
`not-found-time-budget`, `not-found-support`, `backend-error`, and
`internal-invalid`. Invalid profiles and model/schema mismatches fail while the
generator is created.
