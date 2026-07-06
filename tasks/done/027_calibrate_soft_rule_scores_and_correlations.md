# 027. Калибровать soft rule scores и посчитать корреляции правил

## SMART goal

Создать отдельный dataset/experiment шаг для калибровки soft rules. Библиотеку не трогать. На входе есть audited JSON rules и candidate pool с `official_verifier`; на выходе должны быть feature table, calibrated rule dataset, таблица корреляций и отчет, можно ли доверять weak score.

## Зачем это нужно

Сейчас soft rules существуют и могут быть lowered в Racket DSL, но их веса в основном ручные/эвристические. Такой score плохо интерпретируется как вероятность correctness:

- несколько похожих правил могут считать один и тот же сигнал много раз;
- noisy rules могут доминировать clean signal;
- редкие правила могут выглядеть слишком сильными на малом числе срабатываний;
- threshold для `risk_target:0.05` нельзя честно переносить на test/generation без dev calibration.

Калибровка должна жить в dataset/experiment pipeline, а не в Racket core library. Библиотека должна только применять уже заданные веса.

## Scope

Входы:

```text
data/012_soft_ifbench_rules_audited.jsonl
data/012_soft_candidate_pool.jsonl
```

Основной скрипт:

```text
experiments/012_real_model_benchmark/code/calibrate_soft_rules_012.py
```

Выходы:

```text
data/012_soft_rule_feature_table.jsonl
data/012_soft_rule_calibration.csv
data/012_soft_rule_correlations.csv
data/012_soft_ifbench_rules_calibrated.jsonl
experiments/012_real_model_benchmark/results/012_soft_rule_feature_table.jsonl
experiments/012_real_model_benchmark/results/012_soft_rule_calibration.csv
experiments/012_real_model_benchmark/results/012_soft_rule_correlations.csv
experiments/012_real_model_benchmark/results/012_soft_ifbench_rules_calibrated.jsonl
experiments/012_real_model_benchmark/results/027_soft_rule_calibration_report.json
```

Out of scope:

- Не менять Racket core library.
- Не менять sampler.
- Не менять DSL/API.
- Не запускать full generation-time benchmark.
- Не использовать test labels для обучения весов.

## Feature table

Построить таблицу, где одна строка соответствует одному candidate для одного `key/noise`.

JSONL row:

```json
{
  "key": "6",
  "split": "dev",
  "noise": "clean",
  "candidate_id": "6:000",
  "official_verifier": true,
  "fired_rule_ids": ["conj_for_present", "conj_threshold_hint"],
  "raw_score": 3.0
}
```

Правила:

- `split` считать той же функцией, что и Experiment 012: deterministic hash by key, `dev` если bucket `< 3`, иначе `test`.
- `raw_score` считать как сумму исходных `weight` для fired `rank` rules.
- Если fired `ban`, выставлять `raw_score = -Infinity` или сериализуемый эквивалент и добавлять `banned=true`.
- `official_verifier` можно хранить в таблице, но для обучения использовать только `split=dev`.

## Rule calibration table

Одна строка соответствует одному правилу или calibration group.

CSV columns:

```text
key
split_scope
noise
rule_id
source_instruction_id
kind
polarity
noise_type
pattern_type
n_candidates
fire_count
coverage
p_ok_if_fired
p_ok_if_not_fired
lift
raw_weight
calibrated_weight
calibration_key
calibration_status
```

Формулы на dev split:

```text
coverage = fire_count / n

p_ok_if_fired =
  count(fired && official_ok) / count(fired)

p_ok_if_not_fired =
  count(!fired && official_ok) / count(!fired)

lift = p_ok_if_fired - p_ok_if_not_fired
```

Для `rank` веса:

```text
log_odds =
  log((ok_fired + alpha) / (bad_fired + alpha))
  - log((ok_not_fired + alpha) / (bad_not_fired + alpha))

calibrated_weight =
  clip(log_odds * fire_count / (fire_count + shrink_k), -4.0, 4.0)
```

Defaults:

```text
alpha = 1.0
shrink_k = 20.0
clip = [-4.0, 4.0]
```

Backoff order:

```text
rule_id
(source_instruction_id, kind, polarity, noise_type, pattern_type)
original weight
```

`ban` rules:

- остаются hard bans;
- не получают finite `calibrated_weight`;
- `calibration_status = hard_ban`.

## Calibrated dataset

Создать:

```text
data/012_soft_ifbench_rules_calibrated.jsonl
```

Для каждой строки сохранить исходные поля и добавить `calibrated_rule_sets`.

Каждый `rank` rule должен получить:

```json
{
  "calibrated_weight": 1.23,
  "calibration_key": "rule_id:conj_for_present",
  "calibration_status": "ok"
}
```

Если сработал fallback:

```json
{
  "calibration_key": "group:count:conjunctions|rank|positive||regex",
  "calibration_status": "fallback_group"
}
```

Если данных нет:

```json
{
  "calibrated_weight": 1.0,
  "calibration_key": "original_weight",
  "calibration_status": "fallback_original"
}
```

Нельзя silently drop rules: число правил в `rule_sets[noise]` и `calibrated_rule_sets[noise]` должно совпадать.

## Correlation table

Одна строка соответствует паре правил внутри одного `key/noise`.

CSV columns:

```text
key
noise
left_rule_id
right_rule_id
n11
n10
n01
n00
jaccard
phi
duplicate_candidate
```

Формулы:

```text
n11 = count(left=1, right=1)
n10 = count(left=1, right=0)
n01 = count(left=0, right=1)
n00 = count(left=0, right=0)

jaccard = n11 / (n11 + n10 + n01)

phi =
  (n11*n00 - n10*n01)
  / sqrt((n11+n10)(n01+n00)(n11+n01)(n10+n00))
```

Если denominator для `phi` равен `0`, писать пустое значение или `null`.

Duplicate heuristic:

```text
duplicate_candidate = true iff jaccard >= 0.95
```

Корреляции в этой задаче являются диагностикой. Они не должны менять DSL и не должны удалять правила из dataset автоматически.

## Report

Записать:

```text
experiments/012_real_model_benchmark/results/027_soft_rule_calibration_report.json
```

Report должен содержать по каждому noise level:

- number of rows/candidates/rules;
- dev/test label rates;
- raw score AUROC/AUPRC on dev/test;
- calibrated score AUROC/AUPRC on dev/test;
- number of fallback rules by status;
- number of high-correlation duplicate candidate pairs;
- risk/coverage summary for raw vs calibrated scores.

## Tests

Добавить тесты в Experiment 012 test suite:

- `test_soft_rule_feature_table_schema`
- `test_calibration_uses_dev_labels_only`
- `test_no_rule_drops_in_calibrated_dataset`
- `test_ban_rules_remain_hard_bans`
- `test_log_odds_formula_sanity`
- `test_correlation_formula_sanity`
- `test_required_calibration_outputs_exist`
- `test_report_compares_raw_and_calibrated_scores`

## DoD

- Feature table покрывает все audited rows, все `clean/noisy_20/noisy_40`, все candidates из pool для этих keys.
- В calibrated dataset у каждого `rank` rule есть `calibrated_weight`, `calibration_key`, `calibration_status`.
- `ban` rules остаются hard bans.
- Калибровка весов использует только `dev` labels.
- `test` labels используются только для evaluation/report.
- Correlation table содержит `jaccard`, `phi`, `n11`, `n10`, `n01`, `n00`.
- High-correlation pairs явно перечислены или агрегированы в отчете.
- Report сравнивает raw vs calibrated scores по AUROC/AUPRC и risk/coverage.
- Нет изменений в Racket core library, sampler, DSL или public API.
- Новые тесты Experiment 012 проходят.
