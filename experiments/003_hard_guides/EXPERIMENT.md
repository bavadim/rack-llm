# Experiment 003: Hard Guide Builders

## Introduction

The hard IFBench experiments require a fair grammar-constrained subset for our
DSL and for Guidance/Outlines baselines. This experiment implements the first
builder layer: each hard-supported row is converted into a small serializable
grammar/check specification or explicitly rejected as unsupported.

## Methods

The module `code/hard_guides.py` exports:

- `build_ours_hard_guide(row)`
- `build_guidance_hard_grammar(row)`
- `build_outlines_hard_grammar(row)`

Each function returns either `GuideSpec` or `Unsupported`. `GuideSpec` stores a
system name, source string, expected exactness, and either exact choices or a
bounded regex. The checker in the same module is intentionally local and is used
only for synthetic builder tests and for the build report.

The script `code/build_hard_guide_report.py` runs all builders over the pinned
IFBench snapshot and writes:

- `experiments/003_hard_guides/data/hard_guide_build_report.jsonl`
- `data/hard_guide_build_report.jsonl`

Reproduce:

```bash
python3 experiments/003_hard_guides/code/build_hard_guide_report.py
python3 experiments/003_hard_guides/code/test_hard_guides.py
```

## Results

The build report records one row per IFBench example, including whether our
guide, Guidance spec, and Outlines spec were built and why unsupported rows were
excluded. Rows containing any non-hard-supported instruction id are rejected at
this stage instead of silently composing a partial grammar.

## Discussion

This experiment does not run an LLM and does not claim official verifier
agreement. Many builders are deliberately `near_exact` or `bounded`; task 004
must validate them against IFBench's official verifier before a row can enter the
hard benchmark subset. The current artifact is a reproducible builder layer and
coverage report, not a final benchmark.
