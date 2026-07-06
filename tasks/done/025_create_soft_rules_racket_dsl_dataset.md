# 025. Создать soft dataset с JSON RuleSpec и Racket DSL-кодом библиотеки

## SMART goal

Создать производный soft dataset, где каждая IFBench soft row содержит не только исходные JSON/Python `RuleSpec`, но и готовый Racket DSL guide source нашей библиотеки. Этот dataset должен стать входом для generation-time soft benchmark.

## Зачем это нужно

Сейчас soft rules существуют как JSON/Python-описания:

```json
{
  "kind": "rank",
  "weight": 1.0,
  "pattern_type": "regex",
  "pattern": "(?i)\\bkeyword\\b"
}
```

Но наша библиотека ожидает Racket DSL:

```racket
(text
  (rank 1.0 (rx #px"(?i:\\bkeyword\\b)"))
  (ban (rx #px"(?i:secret token)")))
```

Из-за отсутствия стабильного dataset-level lowering soft benchmark компилирует правила ad hoc или вообще не запускает `ours_soft_decoding` как real generation-time method.

## Scope

Вход:

```text
data/012_soft_ifbench_rules_audited.jsonl
```

Выход:

```text
data/012_soft_ifbench_rules_audited_racket.jsonl
experiments/012_real_model_benchmark/results/012_soft_ifbench_rules_audited_racket.jsonl
```

Для каждой строки сохранить:

- `key`
- `prompt`
- `instruction_id_list`
- `kwargs`
- исходный `rule_sets`
- новый `racket_rule_sets`

## `racket_rule_sets` schema

Для каждого noise level:

```json
{
  "watchers": ["(rank 1.0 (rx #px\"...\"))"],
  "guide_source": "(text #:max-tokens 128 ...)",
  "rule_set_hash": "sha256...",
  "lowering_status": "ok|failed",
  "lowering_errors": []
}
```

Noise levels:

```text
clean
noisy_20
noisy_40
```

## Out of scope

- Не менять сами soft rules.
- Не менять audit criteria.
- Не запускать generation benchmark.
- Не использовать official IFBench verifier.

## How

Создать builder:

```text
experiments/012_real_model_benchmark/code/build_soft_racket_dsl_dataset.py
```

Правила lowering:

- `kind=rank` -> `(rank weight expr)`
- `kind=ban` -> `(ban expr)`
- `pattern_type=literal` -> escaped Racket string
- `pattern_type=regex` -> `(rx #px"...")`
- Python inline flags переводить в Racket scoped flags:
  - `(?i)abc` -> `(?i:abc)`
  - `(?m)abc` -> `(?m:abc)`
  - `(?s)abc` -> `(?s:abc)`
- Escapes для Racket должны быть валидны:
  - `\n`, `\t`, quotes and backslashes escape корректно.

Нельзя silently drop rules:

- число JSON rules должно совпадать с числом generated Racket watcher expressions;
- если хотя бы одно правило не lowerится, строка получает `lowering_status=failed`;
- общий build должен fail closed, если `failed_rows > 0`.

## Required outputs

```text
data/012_soft_ifbench_rules_audited_racket.jsonl
experiments/012_real_model_benchmark/results/012_soft_ifbench_rules_audited_racket.jsonl
experiments/012_real_model_benchmark/results/025_soft_racket_dsl_dataset_report.json
```

## Unit tests

- `test_soft_racket_dataset_exists`
- `test_all_rule_sets_have_racket_guide_source`
- `test_no_rule_silent_drop`
- `test_racket_sources_compile`
- `test_regex_flag_translation`
- `test_no_verifier_dependency`

## DoD

- Новый dataset содержит и JSON RuleSpec, и Racket DSL code нашей библиотеки.
- Все audited rows успешно lowered.
- Все `clean`, `noisy_20`, `noisy_40` guide sources проходят Racket validation.
- `024` может использовать этот dataset как единственный источник soft rules для `ours_soft_decoding`.
- Старый JSON-only dataset остается как исходный артефакт, но не является единственным входом generation-time benchmark.
