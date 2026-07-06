# 010. Запустить benchmark soft noisy rules

Status: done

## Reopen note

Предыдущий soft noisy benchmark считается pilot/non-paper-grade и не должен
использоваться как evidence. Задача переоткрыта: реальные generation-time rows
и candidate-pool baselines должны жить в `experiments/`, а библиотека должна
только выполнять публичный DSL/generate API без экспериментальной агрегации.

## SMART goal

На `data/soft_ifbench_rules_audited.jsonl` измерить устойчивость методов к неполным и шумным правилам при noise levels 0%, 20%, 40%. Завершить за 3 рабочих дня после задачи 009.

## Зачем это нужно

Это главный научный эксперимент. Он показывает, что soft-guided decoding полезен, когда правила написаны людьми: простые, точные локально, неполные, конфликтующие, иногда ошибочные. Guidance/Outlines здесь не являются baseline, потому что они решают жесткий closed-world язык, а не ранжирование по слабым наблюдателям.

## Scope

Данные:

```text
data/soft_ifbench_rules_audited.jsonl
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

Noise levels:

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
risk_target 0.05
```

## Out of scope

- Hard Guidance/Outlines comparison.
- Создание новых watchers.
- Финальная статистическая значимость; задача 011.

## Required outputs

```text
results/010_soft_noisy_raw.jsonl
results/010_soft_noisy_summary.csv
results/010_soft_noisy_risk_coverage.csv
```

## Metrics

For each method/noise/N:

```text
FoundOK = FOUND_OK / total
FoundWrong = FOUND_WRONG / total
NotFound = NOT_FOUND / total
ReturnPrecision = FOUND_OK / (FOUND_OK + FOUND_WRONG)
Coverage = (FOUND_OK + FOUND_WRONG) / total
Oracle@N = share of rows with any candidate passing official verifier
SelectionEfficiency@N = FoundOK / Oracle@N
FirstGoldRank = first candidate index passing official verifier, if exists
AUROC weak_score vs verifier
AUPRC weak_score vs verifier
median_latency_ms
mean_generated_tokens
duplicate_rate@N
```

## Main derived metric

Compute:

```text
SafeSolve@5% = max FoundOK over thresholds such that FoundWrong <= 0.05
```

Use thresholds from dev split only. Apply selected threshold to test split.

## Splits

Use deterministic split by `key` hash:

```text
dev: 30%
test: 70%
```

No training split needed unless `weight` uses calibration data; if `weight` is used, take calibration from dev only.

## Sanity requirements

- `oracle_verifier_selection` must be ≥ all real methods on FoundOK at same N.
- `vanilla` with return_policy=always must have NotFound near 0 unless generation fails.
- `weak_rejection` must increase NotFound as threshold rises.
- With noise 40%, FoundWrong should not be hidden; report it explicitly.

## DoD

- Raw JSONL and summary CSV created.
- Results exist for all methods, all N, all noise levels.
- Risk-coverage CSV created.
- `SafeSolve@5%` computed on test using dev-selected threshold.
- Any missing method/noise/N combination is listed in `results/010_missing_runs.json`.

## Result

Переведено на реальные `012_soft_real_*` artifacts: 25 536 raw rows, 336
summary rows, 135 risk-coverage rows, `missing_runs = []`. Входные soft rows:
152 audited rows; test split: 103 examples. `ours_*` rows являются реальными
Racket generation-time runs; pool baselines используют real Qwen candidate pool.
