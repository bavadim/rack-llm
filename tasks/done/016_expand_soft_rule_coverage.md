# 016. Расширить soft rule coverage до paper-grade уровня

## SMART goal

Расширить soft/noisy RuleSpec coverage с текущих 78 rows до минимум 250 rows, ideally около 293 rows, покрывая все non-custom IFBench families. Завершить до генерации real candidate pool.

## Зачем это нужно

Soft experiment сейчас статистически слабый: после аудита осталось 8 rows. Для статьи нужен широкий набор weak watchers, иначе claims по soft generation будут inconclusive.

## Scope

Добавить weak approximate watchers для families:

```text
count:*
format:*
sentence:*
words:*
ratio:*
```

Обновить:

```text
experiments/007_soft_rules/code/soft_rules.py
experiments/002_ifbench_constraint_map/code/build_constraint_map.py
```

или создать совместимый replacement в `experiments/012_real_model_benchmark/code/`, если старые pilot artifacts нельзя менять.

## Out of scope

- Не реализовывать exact official verifier.
- Не импортировать official verifier в rule builder.
- Не обучать веса.
- Не покрывать custom one-off rows, если watcher будет искусственным или слишком exact.

## How

- Для каждой new family добавить:
  - clean positive watchers;
  - clean negative watchers;
  - noisy watchers с sign flip / wrong threshold / substring / case bug where applicable.
- Watchers должны быть weak/approximate.
- Rebuild:

```text
data/soft_ifbench_rules.jsonl
data/soft_rule_coverage_failures.jsonl
```

или `012_*` equivalents.

## Required outputs

```text
data/soft_ifbench_rules.jsonl
data/soft_rule_coverage_failures.jsonl
experiments/012_real_model_benchmark/results/016_soft_rule_coverage_report.json
```

## Unit tests

- `test_soft_supported_rows_at_least_250`
- `test_no_verifier_import_in_soft_rules`
- `test_noise_ratio_still_valid`
- `test_new_high_frequency_families_have_rules`
- `test_no_exact_verifier_patterns_for_soft_mode`

## DoD

- At least 250 rows have `clean/noisy_20/noisy_40` rule sets.
- All non-custom high-frequency unsupported families are either supported or explicitly justified.
- Noise ratios remain within task 007 tolerance.
- Builder remains verifier-free.
