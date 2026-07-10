# 032. Repair exact full-vocabulary soft sampler

Status: done

## Completed 2026-07-09

Closed as a runtime semantics repair without changing public API or sampler
control flow. Exact full-vocabulary sampling remains atomic: each generated
token is selected after a complete vocabulary pass. `#:max-tokens` is the depth
budget for exact generation, and `#:deadline-ms` remains a coarse guard between
generation steps rather than a mid-pass interrupt.

Evidence is covered by `tests/e2e-sampler-test.rkt`:

- real Qwen bounded soft full-vocab application tasks pass;
- candidate metrics prove `vocab-size` candidates per full-vocab token;
- top-k remains a separate approximate policy and is not paper-grade exact;
- latency is checked against the current free-generation baseline.

Verified with `make ci` on 2026-07-09.

## Current status 2026-07-09

The hot-loop deadline requirement was dropped. Exact full-vocabulary sampling
must not be interrupted mid-pass: a partial pass would silently turn exact mode
into another top-k/shortlist approximation. A full-vocab sampling step is
atomic, and generation depth is bounded with `#:max-tokens`.

The current repair track is to keep exact semantics and prove practical
bounded tasks through real Qwen e2e tests, candidate metrics, and latency
budgets. `#:deadline-ms` remains a coarse guard between generation steps, not a
candidate-loop interrupt.

## Problem

Exact full-vocabulary soft decoding remains the main runtime blocker. The
current sampler scans the whole vocabulary and calls filter watcher logic for
each candidate. For Qwen-scale open text this can be expensive. The repair must
optimize or bound meaningful full-vocab use cases without rebranding a partial
candidate scan as exact decoding.

## DoD

- Real Qwen soft full-vocab e2e tests pass for bounded application tasks.
- Candidate metrics prove full-vocab mode evaluates `vocab-size` candidates per
  generated token, not a top-k subset.
- Performance tests compare bounded soft full-vocab tasks against the current
  free-generation baseline and stay within the checked budget.
- `#:max-tokens` is the depth budget for exact full-vocab generation.
- `#:deadline-ms` is documented as a coarse step-boundary guard, not a
  mid-pass interrupt.
- Do not make top-k the main paper-grade result.
- `make ci` passes.
