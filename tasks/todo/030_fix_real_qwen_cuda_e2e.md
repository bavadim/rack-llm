# Task 030. Fix Real Qwen CUDA E2E

## Summary

Real Qwen e2e currently fails before DSL/generation assertions because the CUDA
client stack is inconsistent on this machine.

Observed facts:

```text
torch: 2.11.0+cu128
torch.cuda.is_available(): False
torch warning: CUDA Error 804
nvidia-smi: Driver/library version mismatch
loaded kernel module: 580.167.08
userspace NVML library: 580.173.02
```

The task is to fix the CUDA path, not to replace real e2e with mocks or CPU
fallback.

## Plan

- Fix NVIDIA driver/userspace mismatch first:
  - verify installed `nvidia-driver-*`, `libnvidia-*`, and `nvidia-utils-*`
  - align the loaded kernel module and userspace libraries
  - reboot or reload modules if package state is already correct but the loaded
    module is stale
  - require `nvidia-smi` to pass before touching Racket tests
- Verify Python CUDA smoke in `.venv-realbench`:
  ```sh
  .venv-realbench/bin/python - <<'PY'
  import torch
  print(torch.__version__, torch.version.cuda)
  print(torch.cuda.is_available())
  print(torch.cuda.get_device_name(0))
  PY
  ```
- If `torch==2.11.0+cu128` is incompatible with the working local driver/GPU,
  pin a compatible stable CUDA wheel in `setup_real_backend.py` instead of
  installing the latest package from the `cu128` index.
- Improve Qwen e2e configuration and diagnostics:
  - use Qwen-specific env names:
    - `RACK_LLM_QWEN_MODEL_PATH`
    - `RACK_LLM_QWEN_SIDECAR`
    - `RACK_LLM_QWEN_DEVICE`
    - `RACK_LLM_QWEN_DTYPE`
  - keep default device as `cuda`
  - include command, model path, device, and dtype in real e2e load failures
- Keep e2e real-only:
  - no library mock provider
  - no private fake model
  - no CPU fallback as the primary solution

## Acceptance Criteria

- `nvidia-smi` passes.
- `.venv-realbench` CUDA smoke passes.
- `make realbench-check` passes.
- `raco test tests/e2e-real-test.rkt` passes on GPU.
- `make test` passes.
- `make ci` passes.

Do not mark this task done until the real e2e and `make ci` are actually green.
