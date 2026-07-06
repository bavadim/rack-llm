# Experiment 011: Final Tables And Statistical Analysis

## Introduction

This experiment consumes the hard and soft benchmark artifacts and builds final
tables, statistical comparisons, figures, and claim status notes.

## Methods

The analysis uses deterministic paired bootstrap resampling by `example_id`.
McNemar-style paired outcome tests and signed latency comparisons are computed
with standard-library code, then adjusted with Holm-Bonferroni correction.

Reproduce:

```bash
python3 experiments/011_final_analysis/code/run_final_analysis.py
python3 experiments/011_final_analysis/code/test_final_analysis.py
```

## Results

The runner writes the required CSVs and PNGs under
`experiments/011_final_analysis/results` and
`experiments/011_final_analysis/figures`, with root copies in `data/`.

## Discussion

The hard offline benchmark supports non-inferiority smoke-test claims because
all hard constrained systems solve the same subset. The soft benchmark currently
uses only 8 audited rows from an offline candidate pool, so soft superiority
claims are marked conservatively in `011_claims.md`.
