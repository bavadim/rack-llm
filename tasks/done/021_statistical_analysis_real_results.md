# 021. Посчитать статистику и финальные таблицы по real 012 results

## SMART goal

Собрать final paper tables, statistical tests, plots, and claims только из `012_*` real artifacts. Старые `005-011` pilot outputs не должны использоваться как evidence.

## Зачем это нужно

Нужно отделить реальные выводы от pilot/synthetic результатов и формально проверить claims.

## Scope

Входи:

```text
data/012_hard_real_raw.jsonl
data/012_soft_real_raw.jsonl
data/012_soft_real_summary.csv
```

Статистика:

- paired bootstrap by `example_id`;
- McNemar tests;
- Wilcoxon signed-rank for latency/tokens;
- Holm-Bonferroni correction.

## Out of scope

- Не запускать generation.
- Не менять rules.
- Не читать pilot `005-011` как basis для claims.

## Main comparisons

Hard:

```text
ours_hard vs guidance_hard
ours_hard vs outlines_hard
```

Soft:

```text
ours_soft_decoding vs weak_posthoc_rerank
ours_soft_decoding vs weak_rejection
ours_hybrid_decoding vs weak_posthoc_rerank
ours_hybrid_decoding vs best_of_n_lm
```

## Success criteria

Hard non-inferiority:

```text
SolveRate diff CI lower bound >= -0.02
WrongRate <= 0.01
median latency ratio CI upper bound <= 1.25
```

Soft superiority:

```text
SafeSolve@5% improvement >= +5 percentage points
95% bootstrap CI excludes 0
p < 0.05 after Holm-Bonferroni
```

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_hard_final_table.csv
experiments/012_real_model_benchmark/results/012_soft_final_table.csv
experiments/012_real_model_benchmark/results/012_stat_tests.csv
experiments/012_real_model_benchmark/results/012_claims.md
experiments/012_real_model_benchmark/figures/012_hard_solve_vs_time.png
experiments/012_real_model_benchmark/figures/012_soft_risk_coverage.png
experiments/012_real_model_benchmark/figures/012_noise_robustness.png
experiments/012_real_model_benchmark/figures/012_first_gold_rank.png
```

Root copies in `data/` are also required for CSV/MD outputs.

## Unit tests

- `test_bootstrap_resamples_by_example`
- `test_missing_rows_not_dropped`
- `test_pilot_results_not_used`
- `test_oracle_not_in_main_comparison`
- `test_claims_require_real_artifacts`

## DoD

- Final tables and figures created from `012_*` only.
- Statistical tests include adjusted p-values.
- Claims marked `supported`, `not_supported`, or `inconclusive`.
- If input is missing or synthetic, task fails closed.
