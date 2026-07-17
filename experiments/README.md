# PWSeq-IFBench experiments

This directory contains the single frozen experiment program for the four
PWSeq-IFBench claims:

1. exactness of the hard CARS sampler;
2. empirical weakness and conflict of the regular rules;
3. zero-label calibration versus equal voting;
4. posterior-weighted selective generation.

The program is fail-closed.  Development and static tests happen before
`freeze`; after a manifest has been frozen, runtime failures are appended to
`artifacts/<run-id>/issues.jsonl` and are not repaired under that run id.
Independent stages continue and their final state is recorded separately.

The finite-distribution target used by the hard exactness experiment is
`Q_T`: generation stops at the first EOG before the horizon, or at a virtual
STOP after exactly `T` content tokens.  EOG is not part of the returned text.
Both CARS and naive rejection are evaluated against the same `Q_T` conditioned
on hard acceptance.

```bash
make -C experiments bootstrap
make -C experiments prepare
make -C experiments test
make -C experiments freeze
make -C experiments run-all
make -C experiments analyze
make -C experiments archive
```

Generated data lives in `data/pwseq-ifbench/`. Runtime artifacts live under
`experiments/artifacts/<run-id>/` and are entirely ignored by Git. `archive`
creates an immutable tar.zst plus SHA-256 under
`/mnt/storage/work/rack-llm-results` (override with `PWSEQ_ARCHIVE_DIR`).

## Runtime resources

The frozen `runtime` object in `config/paper.json` controls execution:

- `generation_workers` is the total number of independent model processes;
- `gpu_devices` maps worker `i` to device `i mod len(gpu_devices)` through
  `CUDA_VISIBLE_DEVICES`, so the same program works on one or several GPUs;
- `regex_threads` is the OpenMP width of each exact PCRE2 vocabulary scan;
- `model_threads` is the llama.cpp generation CPU width;
- `batch_threads` is the prefill/decode CPU width and `factor_threads` is the
  number of independent vocabulary scans run in parallel;
- `cohort_width` is the immutable physical cohort width (32);
- `context_size` is the logical context per owned sequence; hybrid models own
  both a template and an active sequence per cohort lane;
- `batch_size` and `ubatch_size` freeze llama.cpp's logical and physical token
  batches.

On the 32-thread/RTX 3090 reference host the frozen path is one model process,
fixed cohorts of 32 independent jobs, 16 batch/factor threads, `n_batch=8192`,
and `n_ubatch=512`.  Prompt seed groups are never split across cohorts and
finished slots are not refilled.  Qwen hybrid reset uses a frozen template
sequence plus `llama_memory_seq_cp`; partial recurrent rollback is never used.

All models use non-unified KV, fixed full-width decode, and pinned lane/sequence
IDs.  Phi and hybrid Qwen3.5 pass the same-profile replay gate on CPU and GPU.
SWA remains a model property; there are no model-name fallbacks or scalar
execution paths.  Every science row records the complete execution profile and
cohort width.

`observe` opens only the tokenizer vocabulary; `fit-score` and `score` do not
open llama.cpp at all.  Generation cohorts always save the
post-prefill prompt state and corresponding logits for exact lane-local reset.

Each resource configuration is included in the runner command fingerprint.
Changing threads, devices, context size, or cohort width therefore
invalidates cached artifacts instead of silently reusing results from another
runtime layout.
