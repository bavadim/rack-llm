# Experiment 009: Soft Methods And Outcomes

## Introduction

Soft noisy-rule experiments need a common wrapper for method outputs. The
wrapper separates successful returns, wrong returns, and abstentions.

## Methods

This experiment adds:

- `experiments/ifbench/outcomes.py`
- `experiments/ifbench/soft_methods.py`

The methods operate over an already materialized candidate stream. That keeps
generation out of scope for this task and lets Experiment 010 reuse the same
selection logic with an offline candidate pool.

Reproduce:

```bash
python3 experiments/009_soft_methods/code/test_soft_methods.py
```

## Results

Implemented methods:

- `vanilla`
- `best_of_n_lm`
- `weak_posthoc_rerank`
- `weak_rejection`
- `ours_soft_decoding`
- `ours_hybrid_decoding`
- `oracle_verifier_selection`

Real methods reject an `official_verifier` argument. Only
`oracle_verifier_selection` can use it during selection.

## Discussion

The return-policy layer supports `always`, `min_score`, and `risk_target`.
Risk-target thresholds are selected from dev `(score, accepted)` pairs and can
therefore be reused by the benchmark split logic in Experiment 010.
