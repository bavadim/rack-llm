# Experiment 006: Offline Hard Convergence Curves

## Introduction

The hard solve benchmark reports whether a method eventually solves a row. This
experiment asks how quickly the same methods solve under time, token, and attempt
budgets. It uses the offline hard-solve raw results from Experiment 005.

## Methods

The runner `code/run_hard_convergence.py` reads
`data/005_hard_solve_raw.jsonl` and evaluates four methods:

- `ours_hard`
- `guidance_hard`
- `outlines_hard`
- `vanilla_nucleus_posthoc`

For every method, row, seed, and budget, the script recomputes the budgeted
outcome. A `FOUND_OK` or `FOUND_WRONG` event counts only if the corresponding
resource use is within the budget. Otherwise the budgeted result is `NOT_FOUND`.
The script writes raw budgeted rows, summary CSVs, and PNG line charts.

Reproduce:

```bash
python3 experiments/006_hard_convergence/code/run_hard_convergence.py
python3 experiments/006_hard_convergence/code/test_hard_convergence.py
```

## Results

The experiment writes:

- `results/006_hard_convergence_raw.jsonl`
- `results/006_hard_solve_by_time.csv`
- `results/006_hard_solve_by_tokens.csv`
- `results/006_hard_solve_by_attempts.csv`
- `figures/006_hard_solve_by_time.png`
- `figures/006_hard_solve_by_tokens.png`

Root-level copies of the raw and CSV artifacts are also written under `data/`.
The hard methods solve all rows within the configured budgets in the offline
spec-materialization setting. The vanilla posthoc baseline remains unsolved
because no model/candidate cache is available.

## Discussion

This is still an offline convergence benchmark, not a model-runtime latency
study. It measures the convergence of validated hard specs and preserves the
budget accounting needed for later model-backed reruns. `FOUND_WRONG` remains a
separate outcome and is not folded into `NOT_FOUND`.
