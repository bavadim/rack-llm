# Experiment 007: Clean And Noisy Soft Rule Sets

## Introduction

The paper's soft-generation method needs weak structural rules that can guide
generation without becoming exact official verifiers. This experiment builds
clean and noisy watcher sets for every IFBench row whose instruction ids are all
soft-supported in `data/ifbench_constraint_map.json`.

## Methods

The module `code/soft_rules.py` exports:

```python
build_soft_rules(row, noise_level: float) -> list[RuleSpec]
```

where `noise_level` is `0.0`, `0.2`, or `0.4`. Clean rules are incomplete local
watchers (`rank` or `ban`) based on row kwargs and instruction id. Noisy rules
are deterministic by row key and noise level; they add sign flips, approximate
matches, wrong delimiters, and related weak-rule mistakes according to the task
specification. Universal negative/refusal rules are included in every rule set.

The builder script writes:

- `experiments/007_soft_rules/data/soft_ifbench_rules.jsonl`
- `data/soft_ifbench_rules.jsonl`
- `experiments/007_soft_rules/data/soft_rule_coverage_failures.jsonl`
- `data/soft_rule_coverage_failures.jsonl`

Reproduce:

```bash
python3 experiments/007_soft_rules/code/build_soft_rules.py
python3 experiments/007_soft_rules/code/test_soft_rules.py
```

## Results

The pinned IFBench snapshot contains 78 rows where all instruction ids are
soft-supported. Each emitted row has `clean`, `noisy_20`, and `noisy_40` rule
sets. This is below the 200-row desired threshold because the soft-supported
subset is smaller than 200 rows, so the builder also writes a coverage-failures
artifact explaining which rows were excluded by unsupported instruction ids.

## Discussion

This experiment does not import or call the official verifier and does not train
weights. The rules are intentionally weak: they reward local patterns and
surface structure, while task 008 will audit coverage, lift, and duplication on
a candidate pool.
