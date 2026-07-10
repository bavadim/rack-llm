# Experiment 012: Real Local Model Benchmark

## Introduction

Experiment 012 is the paper-grade entrypoint for real local-model runs. It
requires the native llama.cpp GGUF backend for our Racket path and runtime
Guidance/Outlines baselines for hard comparisons.

## Methods

The runner is fail-closed. If any required runtime dependency is missing, it
writes `MISSING_BACKEND.md` and does not create benchmark result CSV/JSONL
files. Required runtime inputs:

- `RACK_LLM_GGUF_MODEL`: local GGUF model file for the native llama.cpp backend.
- `RACK_LLM_HF_MODEL`: optional Hugging Face model directory for Guidance and
  Outlines baselines.
- Python packages `guidance` and `outlines`.
- Existing IFBench snapshot, hard subset, and audited soft rules.

Soft `ours_*` main results must use native llama.cpp full-vocabulary logits.

Guidance regex support is not disabled globally. The hard runtime runner excludes
only unbounded/open Guidance regex rows from paired comparisons, for example
patterns with `.*`, `.+`, `\S+`, unbounded character classes, or `{n,}`. Guidance
documents that regex `max_tokens` is "not exact" and that variable-length regex
generation may continue after a complete match, so `guidance.gen(regex=...,
max_tokens=...)` is not paper-grade evidence for hard `fullmatch` constraints:
https://guidance.readthedocs.io/en/latest/generated/guidance.gen.html. Guidance
maintainers also discuss regex complexity as a practical limitation:
https://github.com/guidance-ai/guidance/discussions/1108. Bounded/structured
Guidance regex rows remain enabled. Outlines remains enabled for regex rows; its
regex generator documents a validity guarantee while noting that index
construction can take time:
https://dottxt-ai.github.io/outlines/reference/generation/regex/.

Reproduce preflight:

```bash
python3 experiments/012_real_model_benchmark/code/run_real_model_benchmark.py --allow-missing
python3 experiments/012_real_model_benchmark/code/test_real_model_benchmark.py
```

## Results

No placeholder result is produced by this experiment. In an unconfigured
environment, only `MISSING_BACKEND.md` is expected.

## Discussion

This experiment replaces pilot claims with a stricter benchmark gate. Future
paper claims should consume `012_*` artifacts only when preflight passes and real
runtime outputs exist.
