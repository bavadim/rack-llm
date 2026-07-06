# Reproduce Experiment 012

This package is the paper-grade real benchmark package. Pilot artifacts `005-011` are non-paper-grade and must not be used as evidence for claims.

## Environment

- Create `.venv-realbench` and install `experiments/012_real_model_benchmark/requirements.txt`.
- Ensure Racket is on `PATH`.
- Model path: `/mnt/storage/models/qwen/Qwen3.5-4B`.

## Commands

```bash
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_soft_rules_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py --help
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/normalize_soft_candidate_pool.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/audit_soft_rules_012.py
racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10
racket experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt --samples 16 --provider-mode exact-full-vocab --max-tokens 96
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_hard_runtime_benchmark.py --mode full
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_soft_benchmark_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_analysis_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_repro_package_012.py
```

## Artifact Hashes

`ARTIFACT_MANIFEST.json` records sha256 for 15 final artifacts.
