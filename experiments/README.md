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

Dataset authoring and model evaluation are deliberately separate. Two isolated
verifier-blind Codex authors supplied the ten weak rules per family, and a
third isolated reviewer audited them before any v4 candidate generation. The
two replacement-family splits, noise overlays, and mixed tasks were then
materialized exactly once as the committed dataset. No experiment command
regenerates these files. Qwen and Phi are candidate generators only. Exact
packets, reviewer decisions, coordinator disclosure, and hashes are frozen in
`data/pwseq-ifbench/`.

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

`power` is a fail-closed dev-only gate. It runs only after
`DESIGN_COMPLETE`, requires all 12 clean `main_design` EM cohorts to be `OK`,
and rejects any generation row with `calibration_status=ERROR`. The test size
and per-family allocation come from the frozen dataset manifest; only that
split structure is used, never test labels. The resulting artifact reports
both achieved power and `required_prompts_per_family`.

Legacy failed `paper-v5` design runs can be evaluated only as an explicit
retrospective diagnostic, stored under a separate content-addressed `diag-*`
artifact root:

```bash
make -C experiments diagnose-failed SOURCE_RUN_ID=$DESIGN_RUN
```

This command rejects test rows, never writes canonical labels into the source
run, and marks every result posthoc/non-confirmatory. It reports the historical
gate blockers separately from retrospective signals; it cannot repair or
resume the failed run. The current protocol has no technical rule-selection
gate: every frozen rule is passed to calibration, and an unidentifiable family
is recorded as a failed calibration cohort without a fallback posterior.

`record-design` stores the dev-derived operating design and supersedes the
design run only when `achieved_power >= power_target`; otherwise it fails
closed and does not finalize the confirmatory design. On low power, extend the
frozen test split (and its overlays/manifest) to at least the reported
`required_prompts_per_family`, increment the dataset and experiment revision,
and start a new dev-only design run. Test labels remain unread throughout this
decision. After a passing design gate, commit the resulting config and create
the separate confirmatory run:

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

Calibration and candidate evaluation both use 20 fixed `T=1.0` seeds per
prompt (600 candidates per calibration family and 20 per dev/test/OOD task).
`T=1.0` is also the generation temperature. There is no `T=0.7` fit mixture,
technical filtering, selected-slot representation, or fit fallback. Ordered
rule IDs and polarities define a schema identified by dataset revision, family,
and noise level; concrete parameterized matchers remain instance-specific.
Observations and saved calibrations carry that schema and fail closed on a
mismatch.

For each family and base model, the 30 calibration prompts define the
unlabelled target population used by EM: the model produces 20 hard-only
strings per prompt, the ten expert rules are applied to those strings, and EM
sees only the resulting rule matrix. It never receives the official IFBench
outcome. Dev, committed test, and official OOD prompts are disjoint and are
used only after that family/model/noise calibration has been frozen.

The primary PWSG policy is frozen explicitly as `good_multiplier=1` and
`bad_multiplier=0`, so terminal mass equals the learned posterior. Affine
reweighting with positive bad-class mass is supported by the library but is
not silently substituted into the primary experiment.

The frozen Qwen calibration strings from run `3783162ba5b7f01a` may be
imported only through the cache-lineage entry in `config/paper.json`. The
source manifest, rendered prompts, exact GGUF bytes, tokenizer fingerprint,
llama.cpp revision, execution profile, clean split hashes, candidate
identities, and cardinality are verified before import. Imported v2 rows are
normalized explicitly to the current artifact schema, a new run writes a
complete lineage artifact, and every weak observation is recomputed. Missing
dev seeds and all test/OOD/Phi candidates are generated normally.
Import is additionally restricted to the free-text hard envelope used by
calibration/dev, so no candidate produced through the pre-fix nontrivial CARS
prefix path is reused.

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

The v4 weak matcher sends the translated ERE directly to PCRE2's search API;
it no longer surrounds anchored rules with greedy whole-text wildcards. On the
retired v3.1 word-count pilot, the optional legacy checker reports 3 changed
labels out of 3,360: those old rows had exhausted the backtracking match limit
and therefore were backend-error artifacts, not a language-equivalence oracle.
The native terminal matcher now runs exact DFA matching first, without paying a
backtracking or JIT match limit before reaching the exact engine. No v3.1
observation or score is reused by v4. `make regex-benchmark` compiles and
matches the original ambiguous `*`-separator pattern shape over the former
480-candidate hotspot without a model.

Each resource configuration is included in the runner command fingerprint.
Changing threads, devices, context size, or cohort width therefore
invalidates cached artifacts instead of silently reusing results from another
runtime layout.
