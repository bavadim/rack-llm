# EXP-014 — Главный эксперимент Weak-IFBench

## SMART goal

За 5–7 рабочих дней собрать главный эксперимент статьи: сравнить полный метод `Gumbel + Dawid–Skene + weak rules` с baseline-методами на Weak-IFBench при одинаковом бюджете кандидатов.

## Notebook

`experiments/notebooks/014_main_weak_ifbench_experiment.ipynb`

## Hypothesis

Полный метод должен давать лучший `GoldSuccess@B` и `SelectionEfficiency@B` при том же бюджете \(B\), потому что:
1. Gumbel-stream снижает повторы и повышает разнообразие кандидатов;
2. Dawid–Skene лучше агрегирует слабые конфликтующие правила, чем majority/equal weights.

## Dataset

Weak-IFBench, построенный поверх IFBench:
- official verifier используется только для gold evaluation;
- метод видит только prompt, constraints metadata и weak rules.

## Methods to compare

| method_id | Description |
|---|---|
| `pass1_greedy` | Один greedy output |
| `independent_majority_B` | B независимых samples + majority weak rules |
| `independent_equal_B` | B независимых samples + equal weights |
| `independent_ds_B` | B независимых samples + DS |
| `gumbel_majority_B` | Gumbel-stream + majority |
| `gumbel_equal_B` | Gumbel-stream + equal weights |
| `gumbel_ds_B` | основной метод |
| `oracle_verifier_B` | upper bound, использует official verifier |

Если Gumbel-stream еще не готов в core-библиотеке, notebook должен:
- пропустить gumbel methods;
- сохранить `blocked_by = "missing_gumbel_stream_api"` в metadata;
- не подменять Gumbel independent sampling, потому что рецензенты тоже иногда умеют читать.

## Scope

- Запустить все методы на одном и том же наборе задач.
- Использовать одинаковые budgets:
  ```python
  BUDGETS = [1, 2, 4, 8, 16]
  ```
- Использовать одинаковые seeds:
  ```python
  SEEDS = [1, 2, 3]
  ```
- Сохранить сырые кандидаты, rule outputs, selected outputs, metrics.

## Out of scope

- Не менять weak rules.
- Не менять DS-алгоритм.
- Не оптимизировать prompt после просмотра test.
- Не сравнивать `Success@16` с чужим `pass@1` как будто это честно. Ну пожалуйста.

## Primary metrics

\[
GoldSuccess@B=\frac{1}{N}\sum_i g_i(y_i^*)
\]

\[
Oracle@B=\frac{1}{N}\sum_i\mathbf{1}[\exists m\le B:g_i(y_i^{(m)})=1]
\]

\[
SelectionEfficiency@B=GoldSuccess@B/Oracle@B
\]

## Secondary metrics

- `ConstraintSuccess@B`
- `DuplicateRate@B`
- `AvgAcceptedRank`
- `FailRate`
- `LatencyMsMean`
- `TokensOutMean`
- `RuleEvalMsMean`
- `Brier`
- `ECE`
- `AUROC`

## Expected output format

`selected_outputs.jsonl`:

```json
{
  "task_id": "...",
  "method": "gumbel_ds_B",
  "budget": 8,
  "seed": 1,
  "selected_candidate_index": 4,
  "selected_text": "...",
  "accepted_by_method": true,
  "gold_success": true,
  "oracle_success": true,
  "ds_min_posterior": 0.83,
  "latency_ms_total": 4420.1
}
```

`summary.csv`:

| method | budget | gold_success_mean | gold_success_std | oracle_at_b | selection_efficiency | duplicate_rate | avg_accepted_rank | latency_ms_mean |
|---|---:|---:|---:|---:|---:|---:|---:|---:|

Figures:

```text
figures/gold_success_vs_budget.png
figures/selection_efficiency_vs_budget.png
figures/duplicate_rate_vs_budget.png
figures/calibration_ds.png
```

## Expected result

- `Oracle@B` растет с \(B\).
- `gumbel_*` имеет ниже duplicate rate, чем independent.
- `*_ds_B` имеет выше selection efficiency, чем majority/equal.
- Полный `gumbel_ds_B` — лучший по `GoldSuccess@B` среди честных методов.
- Разрыв между `gumbel_ds_B` и `oracle_verifier_B` показывает потолок для улучшения weak rules.

## Statistical reporting

- Для каждой метрики считать mean/std по seeds.
- Для ключевого сравнения `gumbel_ds_B` vs `independent_ds_B` сделать bootstrap CI 95%.
- Не делать p-value цирк на трех seed без надобности.

## DoD

- Есть полная таблица по всем methods и budgets.
- Есть 4 графика.
- Есть `run_metadata.json` с model/version/seed/dataset.
- Notebook можно запустить на `MAX_TASKS=50` за smoke-время и на full split отдельно.
