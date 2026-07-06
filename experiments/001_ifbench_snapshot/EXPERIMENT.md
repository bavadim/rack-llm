# Experiment 001: IFBench Snapshot And Loader

## Introduction

The paper experiments need a single immutable IFBench snapshot. If later hard
and soft-generation experiments read different IFBench revisions, method
comparisons will not be meaningful. This experiment pins the upstream IFBench
commit, downloads the test JSONL and instruction registry, validates registry
coverage, and emits a canonical local JSONL used by later experiments.

## Methods

The reproducibility script is `code/build_snapshot.py`. It reads IFBench from
the pinned GitHub commit recorded in the script, computes a SHA-256 hash for
each raw input row, preserves the required fields (`key`, `prompt`,
`instruction_id_list`, `kwargs`, `raw_row_sha256`), and writes both local
experiment artifacts and root-level canonical copies:

- `experiments/001_ifbench_snapshot/data/ifbench_snapshot.jsonl`
- `experiments/001_ifbench_snapshot/data/ifbench_snapshot_meta.json`
- `data/ifbench_snapshot.jsonl`
- `data/ifbench_snapshot_meta.json`

The registry is parsed directly from `instructions_registry.py` without
importing IFBench runtime code. The validation tests in `code/test_snapshot.py`
check JSONL validity, required fields, registry coverage, and hash stability.

Reproduce:

```bash
python3 experiments/001_ifbench_snapshot/code/build_snapshot.py
python3 experiments/001_ifbench_snapshot/code/test_snapshot.py
```

## Results

The generated metadata records the upstream IFBench repository URL, commit,
source files, row count, unique instruction count, SHA-256 hashes for the raw
source files, and the UTC creation time. The snapshot JSONL contains one
canonical record per IFBench test row and is the authoritative dataset input for
later hard/soft IFBench experiments.

## Discussion

This experiment deliberately does not run any LLM, verifier, grammar builder, or
soft-rule builder. It only establishes the fixed data substrate. Later
experiments should depend on the root-level `data/ifbench_snapshot.jsonl` copy
or the identical artifact in this experiment directory, and should record if
they filter rows into hard or soft subsets.
