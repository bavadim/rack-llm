# 020. Запустить real soft noisy rules benchmark

## SMART goal

Запустить полный soft benchmark на real audited rows и real Qwen generation. Завершить после задач 017, 018, 019.

## Зачем это нужно

Это главный эксперимент статьи: проверяет, помогает ли soft-guided decoding при неполных и шумных human-like rules.

## Scope

Входи:

```text
data/012_soft_candidate_pool.jsonl
data/012_soft_ifbench_rules_audited.jsonl
```

Методы:

```text
vanilla
best_of_n_lm
weak_posthoc_rerank
weak_rejection
ours_soft_decoding
ours_hybrid_decoding
oracle_verifier_selection
```

Noise:

```text
clean
noisy_20
noisy_40
```

Budgets:

```text
N = 1, 4, 8, 16
```

Return policies:

```text
always
risk_target:0.05
```

## Out of scope

- Не сравнивать Guidance/Outlines в soft mode.
- Не менять rules/audit.
- Не использовать synthetic candidate pool.

## How

- `vanilla`, `best_of_n_lm`, `weak_posthoc_rerank`, `weak_rejection` используют real candidate pool.
- `ours_soft_decoding` и `ours_hybrid_decoding` вызывают real Racket generation.
- `oracle_verifier_selection` использует verifier only as upper bound.
- Threshold for `risk_target:0.05` выбирается на dev split и применяется на test split.

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_soft_real_raw.jsonl
experiments/012_real_model_benchmark/results/012_soft_real_summary.csv
experiments/012_real_model_benchmark/results/012_soft_real_risk_coverage.csv
experiments/012_real_model_benchmark/results/012_missing_runs.json
data/012_soft_real_raw.jsonl
data/012_soft_real_summary.csv
data/012_soft_real_risk_coverage.csv
data/012_missing_runs.json
```

## Metrics

- FoundOK
- FoundWrong
- NotFound
- ReturnPrecision
- Coverage
- Oracle@N
- SelectionEfficiency@N
- FirstGoldRank
- AUROC weak_score vs verifier
- AUPRC weak_score vs verifier
- median latency
- generated tokens
- duplicate rate
- SafeSolve@5%

## Unit tests

- `test_all_method_noise_budget_policy_combinations_exist`
- `test_no_synthetic_sources`
- `test_ours_methods_are_generation_not_posthoc`
- `test_oracle_not_used_by_real_methods`
- `test_risk_threshold_selected_on_dev_only`

## DoD

- Raw, summary, and risk-coverage files created.
- Missing runs file is empty or fully explains missing combinations.
- Real methods never use verifier during generation/selection.
- Benchmark blocked if audited rows < 150.
