# Experiment 002: IFBench Constraint Classification

## Introduction

The hard and soft experiments need explicit, reproducible inclusion rules for
IFBench instruction ids. Hard controlled generation should only use constraints
that can be represented as structural grammars. Soft noisy generation should use
constraints where incomplete local watchers are meaningful. This experiment
classifies every instruction id present in the pinned IFBench snapshot.

## Methods

The script `code/build_constraint_map.py` reads `data/ifbench_snapshot.jsonl`,
collects every instruction id, and writes a classification map to:

- `experiments/002_ifbench_constraint_map/data/ifbench_constraint_map.json`
- `data/ifbench_constraint_map.json`

The hard-supported and soft-supported ids follow the task specification in
`tasks/todo/002_classify_ifbench_constraints.md`. Unsupported ids are retained
with a non-empty reason so later experiments can account for exclusions rather
than silently dropping rows.

Reproduce:

```bash
python3 experiments/002_ifbench_constraint_map/code/build_constraint_map.py
python3 experiments/002_ifbench_constraint_map/code/test_constraint_map.py
```

## Results

The output map contains one record per instruction id in the pinned snapshot.
Each record includes the instruction family, support flags, builder names for
supported modes, the snapshot count, and a short reason. The hard and soft
subsets are both non-empty and are intentionally overlapping for structural
constraints that can be used in either mode.

## Discussion

This experiment does not build grammars, soft watchers, or verifier agreement
reports. It is a reproducible planning artifact for later experiments. Row-level
filtering remains the responsibility of hard-guide construction and agreement
validation, because a supported instruction id may still have individual rows
whose kwargs are insufficient for a faithful grammar.
