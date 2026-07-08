# 034. Regenerate or invalidate real artifacts after runtime repair

Status: todo

## Problem

Current `012_*` artifacts mix valid hard evidence with soft generation-time
rows produced through `top-k-approx`. They should not be treated as fresh exact
soft evidence.

## Dependencies

- `032_repair_exact_full_vocab_soft_sampler.md`
- `033_align_real_benchmark_racket_scripts_with_current_api.md`

## DoD

- Regenerate exact-mode artifacts if 032 makes exact full-vocab practical.
- Otherwise fail-closed invalidate exact soft claims and record infeasible rows
  with explicit reasons.
- `012_missing_runs.json`, `012_soft_real_raw.jsonl`,
  `012_soft_real_summary.csv`, `012_hard_real_raw.jsonl`, and claims/stat tests
  are updated consistently.
- `011_claims.md` and `012_claims.md` do not rely on stale top-k artifacts as
  exact full-vocab evidence.
