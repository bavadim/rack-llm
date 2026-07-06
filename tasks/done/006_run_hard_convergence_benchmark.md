# 006. Измерить скорость сходимости hard-режима

Status: done

## Reopen note

Предыдущие convergence-замеры считаются pilot/non-paper-grade и не должны
использоваться как evidence. Задача переоткрыта, чтобы кривые скорости
считались только из воспроизводимых experiment outputs, а измерение latency,
tokens и attempts оставалось в experiment pipeline.

## SMART goal

На `hard_ifbench_subset.jsonl` построить кривые `SolveRate` по бюджету времени, токенов и попыток для нашей библиотеки, Guidance и Outlines. Завершить за 2 рабочих дня после задачи 005.

## Зачем это нужно

Hard solve benchmark говорит “нашли или нет”. Convergence benchmark говорит “как быстро нашли”. Для практической библиотеки это важнее красивой финальной accuracy: если метод находит через вечность, его можно сразу отправить в музей академических прототипов.

## Scope

Методы:

```text
ours_hard
guidance_hard
outlines_hard
vanilla_nucleus_posthoc
```

Бюджеты:

```text
time_ms: 500, 1000, 2000, 5000, 10000
token_budget: 64, 128, 256, 512
attempt_budget: 1, 2, 4, 8
```

## Out of scope

- Soft/noisy rules.
- Repair-loop prompt engineering beyond baseline from task 005.
- Statistical significance report; только raw curves и summary.

## Required outputs

```text
results/006_hard_convergence_raw.jsonl
results/006_hard_solve_by_time.csv
results/006_hard_solve_by_tokens.csv
results/006_hard_solve_by_attempts.csv
figures/006_hard_solve_by_time.png
figures/006_hard_solve_by_tokens.png
```

## Metrics

For each method and budget:

- `SolveRate(budget)`
- `WrongRate(budget)`
- `NotFoundRate(budget)`
- `TimeToFoundOK`
- `TokensToFoundOK`
- `AttemptsToFoundOK`

## DoD

- Кривые построены для ours/guidance/outlines.
- Для каждого метода есть как минимум 5 seeds или явно указан deterministic mode.
- В raw JSONL можно восстановить, какой бюджет остановил генерацию.
- `FOUND_WRONG` в hard methods отдельно подсвечен, не спрятан в `NOT_FOUND`.

## Result

Пересчитано из обновленного `005_hard_solve_raw.jsonl`. Кривые сохраняют
`FOUND_WRONG` отдельным исходом и показывают `NOT_FOUND` для unsupported
constraints. На 10s/token/attempt budgets hard methods достигают `SolveRate =
0.192982`, `WrongRate = 0`; ограничения покрытия связаны с текущей поддержкой
только finite-choice runtime rows.
