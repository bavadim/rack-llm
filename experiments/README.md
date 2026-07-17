# PWSeq-IFBench experiments

This directory contains the single frozen experiment program for the four
PWSeq-IFBench claims:

1. exactness of the hard CARS sampler;
2. empirical weakness and conflict of the regular rules;
3. zero-label calibration versus equal voting;
4. posterior-weighted selective generation.

The program is fail-closed. Development and static tests happen before
`freeze`; after a manifest has been frozen, runtime failures are appended to
`artifacts/<run-id>/issues.jsonl` and are not repaired under that run id.
Independent stages continue and their final state is recorded separately.

The complete model-free validation is local and does not depend on hosted CI:

```bash
make unit-ci
make experiments-ci
```

The finite-distribution target used by the hard exactness experiment is
`Q_T`: generation stops at the first EOG before the horizon, or at a virtual
STOP after exactly `T` content tokens.  EOG is not part of the returned text.
Both CARS and naive rejection are evaluated against the same `Q_T` conditioned
on hard acceptance.

Dataset authoring and model evaluation are deliberately separate. OpenAI
Codex authored the committed 600-row `test.jsonl`, its held-out parameters and
markers, the weak-rule schemas, noise overlays, and the paired mixed hard+weak
tasks exactly once. No experiment command regenerates these files. Qwen and
Phi do not author or revise any task or rule; they are only the candidate
generators being evaluated. Exact provenance is frozen in
`data/pwseq-ifbench/authoring_provenance.json`.

The first frozen run is a dev-only design run. It never generates a test
candidate and cannot read a test label:

```bash
make -C experiments bootstrap
make -C experiments validate-data
make -C experiments test
DESIGN_RUN=$(make -s -C experiments freeze)
make -C experiments run-design RUN_ID=$DESIGN_RUN
make -C experiments power RUN_ID=$DESIGN_RUN
make -C experiments record-design RUN_ID=$DESIGN_RUN
```

`record-design` stores the dev-derived operating design and supersedes the
design run. It cannot change the dataset. Commit the resulting config, then
create the separate confirmatory run:

```bash
RUN_ID=$(make -s -C experiments freeze)
make -C experiments run-all RUN_ID=$RUN_ID
make -C experiments analyze RUN_ID=$RUN_ID
make -C experiments archive RUN_ID=$RUN_ID
```

The immutable dataset snapshot lives in `data/pwseq-ifbench/`. Runtime artifacts live under
`experiments/artifacts/<run-id>/` and are entirely ignored by Git. `archive`
creates an immutable tar.zst plus SHA-256 under
`/mnt/storage/work/rack-llm-results` (override with `PWSEQ_ARCHIVE_DIR`).

Operational thresholds are fitted globally across families on dev and stored
as immutable artifacts. Test analysis applies those values exactly once. The
primary selective results are SolveRate/Risk/Coverage at that dev-selected
operating point plus normalized partial AURC on the common coverage range.
`pass@5` is emitted only as a separately named secondary estimand. The
published FUSE comparator is labeled as a FUSE-style reimplementation, not as
the official implementation.

Generation reporting treats a prompt, not an individual stochastic sample, as
the analysis unit. The five seeds are averaged within each prompt, families
receive equal macro weight, and prompts are resampled within family for 10,000
bootstrap repetitions. Figure JSONL files contain the same point estimates and
95% intervals used by the tables; PNG files are rendered only from those
machine-readable artifacts.

The primary weak model is fitted only on calibration candidates sampled at
`T=1.0`, which is also the generation temperature. Calibration candidates at
`T=0.7` are retained for the rule audit and for one clean-main-model appendix
ablation, `mixture_0p7_1p0`. That ablation reuses the rule slots selected by
the primary fit, scores the identical `T=1.0` dev/test/official candidates,
and never participates in PWSG, noise runs, or generation.

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
