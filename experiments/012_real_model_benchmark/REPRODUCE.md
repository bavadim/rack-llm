# Reproducing Experiment 012

Prerequisites are Racket, Python 3, the native regex and llama.cpp shims, and a
local GGUF model. Override `RACK_LLM_GGUF_MODEL` when necessary.

```bash
make native
make experiments-ci
make -C experiments/012_real_model_benchmark smoke
make -C experiments/012_real_model_benchmark run
```

The full run calibrates a model independently for every template/noise pair and
is intentionally much larger than the smoke run. Output is streamed as JSONL;
a failed run is incomplete and must not be used as a paper artifact.
