# EXP-012 — Генерация кандидатов и baseline-методы на Weak-IFBench

## SMART goal

За 5 рабочих дней реализовать notebook, который генерирует до \(B=16\) кандидатов на задачу Weak-IFBench и считает baseline-выбор без Dawid–Skene.

## Notebook

`experiments/notebooks/012_candidate_generation_baselines_weak_ifbench.ipynb`

## Hypothesis

При фиксированном бюджете \(B\) независимое sampling дает повторы и неэффективный перебор, а простые weak-rule selectors вроде majority/equal weights выбирают правильные кандидаты хуже, чем будущий Dawid–Skene из EXP-013.

## Dataset

- Weak-IFBench из `EXP-010`.
- Для smoke run: 50 задач.
- Для paper-small: 300 задач.
- Для paper-full: весь test split, если вычислительно возможно.

## Methods

Реализовать baseline-методы:

1. `pass1_greedy`: один ответ, temperature=0.
2. `independent_sampling_B`: \(B\) независимых кандидатов.
3. `best_of_B_majority`: выбрать первый/лучший по majority weak rules.
4. `best_of_B_equal_weights`: выбрать по сумме `accept=+1`, `reject=-1`, `abstain=0`.
5. `oracle_verifier_upper_bound`: выбрать первый кандидат, проходящий official verifier. Это upper bound, не честный метод.

Если Gumbel-stream в библиотеке уже готов — добавить `gumbel_stream_B`. Если нет — оставить заглушку с `SKIP_GUMBEL=True` и задачей на EXP-014.

## Scope

- Генерировать кандидатов.
- Прогонять weak rules из EXP-011.
- Выбирать кандидата baseline-методами.
- Считать gold success через official verifier.

## Out of scope

- Не обучать Dawid–Skene.
- Не оптимизировать prompts.
- Не добавлять новые правила.

## Parameters

```python
BUDGETS = [1, 2, 4, 8, 16]
SEEDS = [1, 2, 3]
MAX_TASKS_SMOKE = 50
TEMPERATURE = 0.7
TOP_P = 0.95
MAX_NEW_TOKENS = 512
```

## Metrics

\[
GoldSuccess@B = \frac{1}{N}\sum_i g_i(y_i^*)
\]

\[
Oracle@B = \frac{1}{N}\sum_i \mathbf{1}[\exists m\le B: g_i(y_i^{(m)})=1]
\]

\[
SelectionEfficiency@B = GoldSuccess@B / Oracle@B
\]

Также:

- `ConstraintSuccess@B`
- `AvgCandidatesUsed`
- `DuplicateRate@B`
- `LatencyMsMean`
- `FailRate`

## Expected output format

`raw_candidates.jsonl`:

```json
{
  "task_id": "...",
  "method": "independent_sampling",
  "budget": 8,
  "seed": 1,
  "candidate_index": 3,
  "candidate_text": "...",
  "gold_prompt_pass": true,
  "gold_constraint_pass": {"c1": true, "c2": false},
  "latency_ms": 812.3,
  "tokens_out": 147
}
```

`metrics_by_task.csv`:

| task_id | method | budget | seed | selected_candidate_index | gold_success | oracle_success | duplicate_rate | latency_ms |
|---|---|---:|---:|---:|---|---|---:|---:|

`summary.csv`:

| method | budget | gold_success | oracle_at_b | selection_efficiency | duplicate_rate | latency_ms_mean |
|---|---:|---:|---:|---:|---:|---:|

## Expected result

- `Oracle@B` растет с бюджетом.
- `GoldSuccess@B` у majority/equal weights ниже `Oracle@B`.
- `DuplicateRate@B` у independent sampling заметен при \(B=8,16\).
- `oracle_verifier_upper_bound` задает потолок, а не сравнивается как метод.

## Unit tests

1. Selector majority выбирает кандидата с большим числом accept.
2. Equal weights корректно считает `accept=+1`, `reject=-1`, `abstain=0`.
3. Oracle selector не используется в методах кроме `oracle_verifier_upper_bound`.

## DoD

- Есть результаты минимум на 50 задачах.
- Все summary-таблицы сохраняются.
- В notebook явно написано, что official verifier нельзя использовать при выборе обычных методов.
