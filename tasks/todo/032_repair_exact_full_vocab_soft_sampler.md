# 032. Repair exact full-vocabulary soft sampler

Status: todo

## Problem

Exact full-vocabulary soft decoding remains the main runtime blocker. The
current sampler scans the whole vocabulary and calls filter watcher logic for
each candidate. For Qwen-scale open text this is too slow, and
`#:deadline-ms` is checked outside the full candidate pass.

Observed local symptom:

```text
synthetic 20k vocab, 20 rank watchers, #:deadline-ms 1
status=error-budget after one generated token and ~67ms
```

That means the library can exceed the budget inside one sampling pass and only
fail after doing work that should have been interrupted.

## DoD

- Add a benchmark/trace that reports one full-vocab sampling pass cost.
- `tests/e2e-sampler-test.rkt` passes against real Qwen.
- Check deadline inside the candidate loop at a fixed interval.
- Return `error-budget` without committing a token when the deadline expires
  during candidate evaluation.
- Optimize obvious watcher hot paths or document exact mode as infeasible for
  current Qwen runtime.
- Do not make top-k the main paper-grade result.
- `make ci` passes.
