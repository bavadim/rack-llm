# Experiment 010: Soft Noisy Rules Benchmark

## Introduction

This is the soft-rule benchmark over the audited rule rows from Experiment 008.
It measures how selection methods behave under clean, 20% noisy, and 40% noisy
watcher sets.

## Methods

The repository has no model backend or candidate cache, so the benchmark replays
the deterministic offline candidate pool produced by Experiment 008. Each method
selects from the first `N` candidates for `N = 1, 4, 8, 16`. Outcomes are
classified with the official verifier labels already stored in the pool.

Return policies:

- `always`
- `risk_target:0.05`, with thresholds selected on the deterministic dev split

Reproduce:

```bash
python3 experiments/010_soft_noisy_benchmark/code/run_soft_noisy_benchmark.py
python3 experiments/010_soft_noisy_benchmark/code/test_soft_noisy_benchmark.py
```

## Results

The runner writes:

- `experiments/010_soft_noisy_benchmark/results/010_soft_noisy_raw.jsonl`
- `experiments/010_soft_noisy_benchmark/results/010_soft_noisy_summary.csv`
- `experiments/010_soft_noisy_benchmark/results/010_soft_noisy_risk_coverage.csv`
- root copies in `data/`

`010_missing_runs.json` is emitted and is empty when every method/noise/N/policy
combination is present.

## Discussion

Because the audited subset currently has only 8 surviving rows, these numbers
are smoke-test benchmark outputs rather than final statistical evidence. Task
011 consumes the artifacts and must mark unsupported claims accordingly.
