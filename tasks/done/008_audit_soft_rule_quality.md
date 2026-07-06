# 008. Провести аудит качества soft/noisy rules на candidate pool

## SMART goal

Проверить, что clean watchers не тривиальны, имеют ненулевую связь с official verifier и не дублируют друг друга. Задача должна быть завершена за 2 рабочих дня после задачи 007.

## Зачем это нужно

Soft rules полностью определяют эксперимент. Если правила всегда молчат, всегда срабатывают или просто копируют verifier, эксперимент будет мусором с графиками. А графики, как известно, умеют делать мусор убедительным, что особенно опасно.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

## Scope

- Создать candidate pool:
  - по 16 vanilla nucleus samples на каждый row из soft subset;
  - если модель недоступна, использовать заранее предоставленный candidate cache и явно указать это в metadata.
- Для каждого candidate вычислить:
  - official verifier result;
  - срабатывания всех watchers;
  - weak score.
- Посчитать качество watchers.
- Сохранить audited rules.

## Out of scope

- Не запускать soft-guided decoding.
- Не сравнивать методы.
- Не строить финальные метрики `FOUND_OK/WRONG/NOT_FOUND`.

## Required outputs

```text
data/soft_rule_candidate_pool.jsonl
data/soft_rule_audit.csv
data/soft_ifbench_rules_audited.jsonl
```

## Metrics per watcher

For each watcher:

```text
coverage = P(watcher fires)
precision_positive = P(verifier true | watcher fires) for positive watchers
precision_negative = P(verifier false | watcher fires) for negative watchers
lift = P(verifier true | fires) - P(verifier true | not fires)
jaccard_to_nearest = max Jaccard(fire_set_i, fire_set_j)
```

## Clean watcher acceptance criteria

Clean watcher is accepted if:

```text
0.02 <= coverage <= 0.98
abs(lift) >= 0.02
jaccard_to_nearest < 0.95
```

For negative clean watchers use negative lift in the correct direction.

## Noisy watcher criteria

Noisy watchers may violate lift criteria, but must:

- have `noise=true`;
- have nonzero coverage;
- not be exact duplicates of clean watcher unless `noise_type=sign_flip`.

## Row-level criteria

Keep row in `soft_ifbench_rules_audited.jsonl` if:

- at least 2 accepted clean positive watchers;
- at least 1 accepted negative watcher or universal negative watcher;
- total clean watchers after filtering ≥ 3.

## Unit tests

- `test_no_trivial_clean_watchers`: no accepted clean watcher has coverage <2% or >98%.
- `test_audit_has_verifier_column`: audit includes gold verifier result only in audit files, not in rule builder.
- `test_audited_rows_have_min_rules`: each audited row has ≥3 clean watchers.

## DoD

- Candidate pool generated or loaded with metadata.
- `soft_rule_audit.csv` created.
- `soft_ifbench_rules_audited.jsonl` created.
- At least 150 rows survive audit; if fewer, create `data/soft_rule_audit_failures.md` with family breakdown.
