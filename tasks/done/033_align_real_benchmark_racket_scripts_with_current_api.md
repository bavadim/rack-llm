# 033. Align real benchmark Racket scripts with current API

Status: done

## Result

Experiment 012 Racket scripts now compile against the current public package
surface when run from the repository checkout with:

```bash
export PLTCOLLECTS=/mnt/storage/work:
raco make experiments/012_real_model_benchmark/code/racket_choice_batch.rkt \
  experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt \
  experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt \
  experiments/012_real_model_benchmark/code/racket_soft_candidate_pool.rkt
```

They use public imports only:

- `rack-llm`
- `rack-llm/model-llama-cpp`

No active Experiment 012 Racket script imports private library modules or the
removed sidecar API names.

## Notes

- The current public real backend is `llama-cpp-model` from
  `rack-llm/model-llama-cpp`.
- `PLTCOLLECTS=/mnt/storage/work:` is required unless the checkout is installed
  as a Racket package.
- Exact soft generation rows are labeled
  `racket_generate_native_llama_cpp_full_vocab` with `approximation=none`.
