# 029. Пересобрать real benchmark artifacts после runtime fixes

Status: todo

## Problem

Код изменен: open `text` больше не завершает generation после первого токена,
soft main mode требует `exact-full-vocab`, hard runtime теперь принимает regex
specs. Старые `012_*`, `010_*`, `011_*` результаты были построены до этих
исправлений и больше не являются evidence.

## DoD

- Пересобраны или fail-closed invalidated:
  - `012_ours_soft_generation_raw.jsonl`
  - `012_soft_real_raw.jsonl`
  - `012_soft_real_summary.csv`
  - `012_missing_runs.json`
  - `012_hard_real_raw.jsonl`
  - `012_hard_real_summary.csv`
  - `005/006/010/011` derived artifacts
- `.venv-realbench/bin/python experiments/012_real_model_benchmark/code/test_real_model_benchmark.py` проходит.
- `011_claims.md` не содержит claims, основанных на stale top-k artifacts.

