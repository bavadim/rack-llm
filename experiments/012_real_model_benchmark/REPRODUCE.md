# Reproduce Experiment 012

This package is the paper-grade real benchmark package. Pilot artifacts `005-011` are non-paper-grade and must not be used as evidence for claims.

## Environment

- Create `.venv-realbench` and install `experiments/012_real_model_benchmark/requirements.txt`.
- Ensure Racket is on `PATH`.
- GGUF model path: `/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`.
- HF model path: `/mnt/storage/models/qwen/Qwen3.5-4B`.
- Run commands from the repository root with:
  - `RACK_LLM_GGUF_MODEL=/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf`
  - `RACK_LLM_HF_MODEL=/mnt/storage/models/qwen/Qwen3.5-4B`
  - `PLTCOLLECTS=/mnt/storage/work:`

## Commands

```bash
export RACK_LLM_GGUF_MODEL=/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf
export RACK_LLM_HF_MODEL=/mnt/storage/models/qwen/Qwen3.5-4B
export PLTCOLLECTS=/mnt/storage/work:

.venv-realbench/bin/python -m pytest -q experiments/012_real_model_benchmark/code/test_real_model_benchmark.py
raco make experiments/012_real_model_benchmark/code/racket_choice_batch.rkt experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt experiments/012_real_model_benchmark/code/racket_soft_candidate_pool.rkt
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_model_benchmark.py --experiment-only --no-write

.venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_soft_rules_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py --limit-rows 1 --candidates-per-row 1 --experiment-only
racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --rules data/soft_ifbench_rules.jsonl --output experiments/012_real_model_benchmark/results/019_ours_soft_smoke_raw.jsonl --limit-rows 1 --max-tokens 1 --attempt-timeout-seconds 10

.venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/normalize_soft_candidate_pool.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/audit_soft_rules_012.py
racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10
racket experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt --samples 16 --max-tokens 96
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_hard_runtime_benchmark.py --mode full
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_soft_benchmark_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_analysis_012.py
.venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_repro_package_012.py
```

## Artifact Hashes

`ARTIFACT_MANIFEST.json` records sha256 for 8 final artifacts.
