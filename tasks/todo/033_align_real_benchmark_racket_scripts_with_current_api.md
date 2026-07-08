# 033. Align real benchmark Racket scripts with current API

Status: todo

## Problem

Experiment 012 Racket scripts still reference stale API/module names:

- `rack-llm/llama-cpp`
- `make-llama-cpp-provider`
- `make-provider`
- `provider-vocab`

The current library exposes `main.rkt`/`rack-llm` facade APIs and
`model-qwen.rkt` with `qwen-model`. These scripts cannot be trusted as current
library integration until they compile against the public API again.

## DoD

- `racket_ours_soft_batch.rkt`, `racket_ours_soft_smoke.rkt`,
  `racket_choice_batch.rkt`, and `racket_sidecar_smoke.rkt` use current public
  API only.
- No experiment Racket script imports library private modules.
- Exact mode uses `qwen-model`/`model-provider`; top-k approximation, if kept
  for engineering smoke, is explicitly labeled non-paper-grade.
- `raco make` passes for the experiment Racket scripts after package/install
  setup or via explicit repo-relative imports chosen for the benchmark.
