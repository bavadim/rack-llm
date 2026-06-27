# Development

Use the Make targets as the release gate:

```bash
make lint
make test
make test-integration
```

`make test` runs deterministic unit tests under `tests/unit`. `make
test-integration` runs slower local integration tests under `tests/integration`;
these tests must not require network access, hosted APIs, or a local model.
Acceptance tests that need llama.cpp or OpenAI stay under `tests/acceptance` and
are gated by environment variables.

Unit tests that need model behavior should use `rack-llm/testing` or
`rack-llm/providers/mock-provider`:

```racket
(require rack-llm/testing)

(define p
  (make-deterministic-mock-provider
   #:vocab '("a" "b")
   #:default-logits '#(0.0 -1.0)))
```

Set `random-seed` explicitly in tests that consume the Gumbel sampler. Provider
state, prompt rendering, and metadata should be explicit values; tests should
not depend on process-global model sessions.
