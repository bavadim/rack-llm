# Experiment 005: Offline Hard Solve Benchmark

## Introduction

This experiment normalizes real hard-runtime outputs from Experiment 012 into
the historical 005 schema. It is fail-closed: rows come from real Racket,
Guidance, and Outlines runs, and missing runtime support is recorded as an
unsupported real-runtime row rather than as a placeholder baseline.

## Methods

The runner `code/run_hard_solve.py` reads:

- `data/hard_ifbench_subset.jsonl`
- `data/012_hard_real_raw.jsonl`
- `data/012_hard_runtime_failures.jsonl`

It evaluates these methods on identical rows and seeds:

- `ours_hard`
- `guidance_hard`
- `outlines_hard`

Every returned candidate is checked by the pinned IFBench official verifier.
Outcomes follow the task definition:

- `FOUND_OK`: candidate returned and official verifier accepts it
- `FOUND_WRONG`: candidate returned and official verifier rejects it
- `NOT_FOUND`: no candidate or budget/cache unavailable

Reproduce:

```bash
/tmp/rack-llm-ifbench-venv/bin/python experiments/005_hard_solve/code/run_hard_solve.py
/tmp/rack-llm-ifbench-venv/bin/python experiments/005_hard_solve/code/test_hard_solve.py
```

## Results

The experiment writes:

- `results/005_hard_solve_raw.jsonl`
- `results/005_hard_solve_summary.csv`

and mirrors them to `data/` for later analysis. The raw file records method,
example id, seed, outcome, latency, generated-token estimate, attempts,
candidate hash, and reason. The summary file reports solve, wrong, and not-found
rates plus latency/token/attempt aggregates.

## Discussion

This is a normalized view over the real hard-runtime benchmark. It intentionally
does not include posthoc placeholder baselines; methods without a real runtime
implementation should be added only when they produce real model rows.
