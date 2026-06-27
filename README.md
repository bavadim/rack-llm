# rack-llm

`rack-llm` is a small Racket library for grammar-constrained LLM generation,
weak-rule acceptance, and reproducible local experiment traces.

The release core is:

```text
grammar -> Gumbel stream -> weak rules -> thresholded acceptance -> traces/metrics
```

## Install

```bash
raco pkg install --auto
make ci
```

For a local llama.cpp backend:

```bash
make env
make server
```

## Minimal Pipeline

```racket
#lang racket

(require json
         racket/stream
         rack-llm
         rack-llm/providers/mock
         rack-llm/providers/provider-v2
         rack-llm/grammar
         rack-llm/sampling
         rack-llm/rules)

(random-seed 7)

(define provider
  (make-mock-provider
   #:vocab '("{\"status\":\"ok\"}")
   #:default-logits '#(0.0)))

(define generated-program
  (stream-first
   (eval (provider->token-oracle provider)
         (list (assistant (gen 1))))))

(define candidate-text
  (message->string (car generated-program)))

(define json-rule
  (rule 'json-object
        "candidate must be parseable JSON"
        'candidate
        (lambda (candidate)
          (with-handlers ([exn:fail?
                           (lambda (_exn)
                             (reject #:message "invalid JSON"))])
            (define parsed (string->jsexpr candidate))
            (if (hash? parsed)
                (accept)
                (reject #:message "not a JSON object"))))))

(define report
  (run-rules
   (acceptance-input candidate-text
                     (list (hard json-rule)))))

(define decision
  (accept-posteriors
   (acceptance-config 'all-constraints 0.5 (hash) (hash))
   report
   (hash 'json 1.0)))

(unless (acceptance-decision-accepted? decision)
  (error 'readme-example
         "candidate rejected: ~a"
         (acceptance-decision-diagnostics decision)))

(displayln candidate-text)
```

Run the README smoke test:

```bash
make test-readme
```

More runnable examples:

```bash
make test-examples
```

- `examples/01-json-grammar.rkt`
- `examples/02-rule-resampling.rkt`
- `examples/03-weak-constraint-mini.rkt`

## Provider Modes

Provider v2 records the mode in metadata:

- `exact-full-vocab`: full logits are available and exact distribution tests are
  allowed.
- `truncated-top-k`: logits are masked to a top-k set; discarded probability
  mass is recorded when known.
- `compat-no-logits`: compatibility path for legacy token or hosted APIs that
  do not expose full logits.

The OpenAI Responses adapter is a compatibility/truncated backend for ordinary
generation workflows. Do not use it for exact full-vocabulary distribution
claims or Gumbel exactness tests.

## Rules And Acceptance

Rules return `accept`, `reject`, or `abstain`. Hard rules gate candidates.
Soft/weak rules can be aggregated by majority, equal weights, or Dawid-Skene
posteriors, then passed through `accept-posteriors` or `accept-candidate`.

Useful modules:

- `rack-llm/rules`
- `rack-llm/rules/dawid-skene`
- `rack-llm/rules/threshold-acceptance`
- `rack-llm/traces/trace`
- `rack-llm/experiments/metrics`
- `rack-llm/experiments/weak-ifbench/runner`

## Documentation

- `docs/provider-v2.md`
- `docs/grammar-and-rules.md`
- `docs/dawid-skene.md`
- `docs/acceptance.md`
- `docs/complexity.md`
- `docs/weak-ifbench.md`
- `docs/migration-token-oracle-to-provider-v2.md`
