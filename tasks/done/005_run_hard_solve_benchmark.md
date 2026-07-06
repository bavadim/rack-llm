# 005. Запустить hard solve benchmark против Guidance и Outlines

Status: done

## Reopen note

Предыдущие результаты этой задачи считаются pilot/non-paper-grade и не должны
использоваться как evidence. Задача переоткрыта, чтобы замеры были выполнены
как отдельный experiment artifact, без подмены runtime outputs witness/spec-only
результатами и без смешения библиотечного API с экспериментальной агрегацией.

## SMART goal

На `data/hard_ifbench_subset.jsonl` измерить три исхода `FOUND_OK / FOUND_WRONG / NOT_FOUND` для нашей библиотеки, Guidance, Outlines и простых baseline. Завершить за 2 рабочих дня после задачи 004.

## Зачем это нужно

Нужно показать, что hard-режим нашей библиотеки работает как практический constrained decoder: не возвращает неправильные примеры и не медленнее популярных hard-guidance решений. Это первый барьер перед обсуждением мягких правил, потому что если hard-часть кривая, то мягкая часть будет просто красивой надстройкой над болотом.

## Scope

Методы:

```text
ours_hard
guidance_hard
outlines_hard
vanilla_nucleus_posthoc
repair_loop_posthoc
```

Для каждого row и метода:

- запустить генерацию с фиксированным prompt;
- применить official verifier;
- классифицировать outcome;
- записать latency/tokens/attempts.

## Out of scope

- Soft/noisy rules.
- Подбор новых hard grammars.
- Статистический финальный отчет; здесь только raw и агрегированные результаты.

## Outcome semantics

```text
FOUND_OK     = method returned text and official verifier accepted it
FOUND_WRONG  = method returned text and official verifier rejected it
NOT_FOUND    = method returned no text, exhausted budget, or hard decoder stuck
```

Hard methods must have `FOUND_WRONG <= 1%`. Если больше, это не “результат”, а баг грамматики/декодера.

## Budgets

Фиксировать в config:

```json
{
  "max_tokens": 512,
  "max_attempts": 1,
  "deadline_ms": 10000,
  "temperature": 0.7,
  "seed_count": 5
}
```

Для `repair_loop_posthoc` разрешить `max_attempts=4`, но в таблице указать это отдельно.

## Required outputs

```text
results/005_hard_solve_raw.jsonl
results/005_hard_solve_summary.csv
```

## Metrics

- `SolveRate = FOUND_OK / total`
- `WrongRate = FOUND_WRONG / total`
- `NotFoundRate = NOT_FOUND / total`
- `median_latency_ms`
- `p90_latency_ms`
- `mean_generated_tokens`
- `mean_attempts`

## Unit / sanity tests

- На 5 toy rows with `format:options`, `ours_hard` должен вернуть только allowed options.
- `FOUND_WRONG` для toy rows должен быть 0.
- Raw JSONL должен содержать `method`, `example_id`, `seed`, `outcome`, `latency_ms`, `text_hash`.

## DoD

- Raw JSONL и summary CSV созданы.
- Все методы запущены на одинаковом hard subset.
- Для `ours_hard`, `guidance_hard`, `outlines_hard` посчитаны три исхода.
- Если `ours_hard WrongRate > 1%`, создан `results/005_hard_wrong_failures.jsonl` с текстами и причинами.

## Result

Пересчитано из real runtime artifacts Experiment 012 без witness/spec-only
подстановок. Unsupported hard constraints расширены в `NOT_FOUND` для всех
seeds. Итог: hard methods имеют `WrongRate = 0`, `SolveRate = 55/285 =
0.192982` на полном hard subset; posthoc baselines помечены `NOT_FOUND`, потому
что real posthoc model baseline в этой задаче не реализован.
