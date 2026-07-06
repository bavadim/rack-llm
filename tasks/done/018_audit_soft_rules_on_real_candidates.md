# 018. Провести audit soft rules на real candidates

## SMART goal

Переаудировать soft/noisy rules на реальном Qwen candidate pool и получить минимум 150 audited rows для main soft benchmark.

## Зачем это нужно

Watcher quality должна проверяться на реальном распределении model outputs. Audit на synthetic pool не доказывает, что rules полезны для generation.

## Scope

Входи:

```text
data/soft_ifbench_rules.jsonl
data/012_soft_candidate_pool.jsonl
```

Метрики watcher-level:

```text
coverage
precision_positive
precision_negative
lift
jaccard_to_nearest
```

## Out of scope

- Не запускать benchmark methods.
- Не менять candidate pool.
- Не использовать verifier в rule builder.

## How

- Использовать criteria из задачи 008:

```text
0.02 <= coverage <= 0.98
abs(lift) >= 0.02
jaccard_to_nearest < 0.95
```

- Для negative watchers учитывать direction of lift.
- Row survives if:
  - at least 2 accepted clean positive watchers;
  - at least 1 accepted negative watcher or universal negative watcher;
  - total accepted clean watchers >= 3.

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_soft_rule_audit.csv
experiments/012_real_model_benchmark/results/012_soft_ifbench_rules_audited.jsonl
experiments/012_real_model_benchmark/results/012_soft_rule_audit_failures.md
data/012_soft_rule_audit.csv
data/012_soft_ifbench_rules_audited.jsonl
data/012_soft_rule_audit_failures.md
```

## Unit tests

- `test_no_trivial_accepted_clean_watchers`
- `test_audited_rows_at_least_150`
- `test_audit_uses_real_candidate_pool`
- `test_gold_verifier_only_in_audit_outputs`

## DoD

- Audit CSV created.
- Audited rules JSONL created.
- Audited rows >= 150.
- If rows < 150, task fails and writes family breakdown; task 020 remains blocked.
