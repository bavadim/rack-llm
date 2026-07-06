# Experiment 005: Offline Hard Solve Benchmark

## Introduction

This experiment measures hard-solve outcomes on the verifier-agreed IFBench
subset from Experiment 004. It is a backend-free benchmark pass: hard methods
materialize one candidate from their grammar spec and then run the official
IFBench verifier. Vanilla and repair-loop posthoc baselines require an LLM or a
candidate cache; because neither is present in this repository state, they are
run as explicit `NOT_FOUND` baselines with reason `no_model_or_candidate_cache`.

## Methods

The runner `code/run_hard_solve.py` reads:

- `data/hard_ifbench_subset.jsonl`
- `data/hard_guide_build_report.jsonl`

It evaluates these methods on identical rows and seeds:

- `ours_hard`
- `guidance_hard`
- `outlines_hard`
- `vanilla_nucleus_posthoc`
- `repair_loop_posthoc`

For hard methods, a candidate is generated from the validated grammar spec. For
posthoc methods, no candidate is produced unless a future candidate cache is
added. Every returned candidate is checked by the pinned IFBench official
verifier. Outcomes follow the task definition:

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

This is not a final model-backed comparison against Guidance or Outlines runtime
libraries. It is a reproducible hard-grammar sanity benchmark that proves the
agreed hard specs can produce verifier-accepted outputs and that no wrong hard
outputs are returned in this offline setting. A later model-backed rerun should
replace the posthoc `NOT_FOUND` baseline rows with real cached generations.
