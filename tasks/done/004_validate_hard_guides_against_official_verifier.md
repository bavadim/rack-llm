# 004. Проверить agreement hard-грамматик с official IFBench verifier

## SMART goal

Построить финальный `hard_ifbench_subset.jsonl`, включающий только строки, где hard-грамматики нашей библиотеки, Guidance и Outlines согласуются с official verifier с точностью не ниже 99%. Завершить за 2 рабочих дня после задачи 003.

## Зачем это нужно

В hard-режиме `FOUND_WRONG` должен означать ошибку конвертации или баг декодера, а не “ну грамматика почти такая”. Сравнение с Guidance/Outlines честно только на строках, где все три системы реализуют один и тот же constraint.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

## Scope

- Для каждой строки с `hard_supported=true` построить grammar для ours/guidance/outlines.
- Создать validation pool:
  - official prompt candidates: 16 vanilla samples per row, если уже есть sample cache; если нет, использовать заглушку и выполнить позже;
  - synthetic valid strings from builder;
  - synthetic invalid strings from builder.
- Проверить:
  - `official_verifier(text)`
  - `ours_check(text)`
  - `guidance_check(text)` если доступно;
  - `outlines_check(text)` если доступно.
- Сохранить только rows, где agreement ≥ 0.99.

## Out of scope

- Не запускать финальный hard benchmark.
- Не запускать soft/noisy experiments.
- Не подбирать грамматики вручную после проверки без обновления builder code.

## Required outputs

```text
data/hard_ifbench_subset.jsonl
data/hard_guide_agreement_report.csv
data/hard_guide_agreement_failures.jsonl
```

## Agreement rules

Для каждой строки:

```text
agreement = mean(ours_check(text) == official_verifier(text)) over validation pool
```

Row включается, если:

```text
ours agreement >= 0.99
guidance agreement >= 0.99
outlines agreement >= 0.99
```

Если checker для Guidance/Outlines недоступен, допустимо использовать generated samples + official verifier, но такой row помечается `baseline_check_limited=true`.

## Unit tests

- `test_agreement_report_has_all_rows`: report содержит все attempted rows.
- `test_subset_only_agreed_rows`: subset не содержит rows с agreement < 0.99.
- `test_failures_have_reason`: все исключенные rows имеют `failure_reason`.

## DoD

- `data/hard_ifbench_subset.jsonl` создан.
- Agreement report создан.
- Все included rows имеют agreement ≥ 0.99.
- Не менее 50 rows включены; если меньше, создать `hard_subset_low_coverage.md` с объяснением, какие families не прошли и почему.
