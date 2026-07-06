# Добавить trace и технические метрики в библиотечные результаты

Status: done

## Reopen note

Текущая реализация оставляет timing/measurement поля (`latency-ms`,
`rule-time-ms`, `llm-time-ms`) в публичных библиотечных результатах. Нужно
пересмотреть границу: библиотека может возвращать trace/debug state, но
benchmark measurement и агрегация должны жить в `experiments/`, если поле не
является частью минимального runtime contract.

## SMART goal

За 2 рабочих дня сделать трассировку правил и технические счетчики, пригодные для отладки и внешних измерений.

## Dependencies

Зависит от `013`, `014`, `017` желательно.

## Scope

- Trace должен фиксировать:
  - matched ranks;
  - rank score;
  - bans;
  - weighted watcher contributions;
  - hard failures;
  - final value.
- Metrics должны фиксировать:
  - steps;
  - generated-tokens;
  - llm-calls;
  - dead-prefixes;
  - rule-time-ms;
  - llm-time-ms;
  - provider-mode;
  - attempts.
- Данные должны быть в `generation-result` и `check-result`.

## Out of scope

- Не писать JSONL exporters.
- Не считать benchmark metrics.
- Не строить графики.

## Public interfaces / touched interfaces

```racket
(generation-result-trace r)
(generation-result-metrics r)
(check-result-trace c)
```

## Scientific / design notes

Трасса нужна для разработки: иначе soft-guidance превращается в “модель почему-то выбрала это”. Библиотека должна объяснять, какие локальные правила повлияли на score.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `rank` match появляется в trace.
- `ban` match появляется в failures.
- `dead-prefixes` увеличивается на hard-dead токенах в controlled mock.
- Time fields присутствуют и являются числами.

## Integration tests

- `generate` и `check` возвращают trace одинакового формата.
- Trace достаточно стабилен для snapshot tests.

## Definition of Done

- [x] Trace/metrics реализованы.
- [x] Документирована схема trace.
- [x] Нет экспериментальных агрегаторов, только raw library-level data.

## Result

`check-result` получил metrics; generation metrics теперь включают steps,
generated-tokens, llm-calls, dead-prefixes, rule-time-ms, llm-time-ms,
provider-mode, attempts и latency-ms. Trace дополняется `final-value`, weighted
watcher contributions и failure entries. Добавлен `docs/trace.md`.

Reopen resolved: documentation now states that library metrics are debug/runtime
counters only. Benchmark latency, aggregation, confidence intervals, and plots
are computed outside the library in `experiments/` through the public API.
