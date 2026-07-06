# Написать короткие библиотечные примеры и документацию

## SMART goal

За 2 рабочих дня добавить минимальные examples, показывающие библиотеку как рабочее средство без экспериментальной обвязки.

## Dependencies

Зависит от основных API задач `001-019`.

## Scope

- Создать `examples/` с 4 файлами:
  1. hard select;
  2. text with rank/ban;
  3. bind values / arithmetic;
  4. weighted observer.
- Создать `docs/design.md` на основе архитектуры.
- Создать `docs/status.md`, `docs/provider.md`, `docs/weight.md`, если они не созданы в задачах.
- Все examples должны запускаться через mock provider.

## Out of scope

- Не писать IFBench examples.
- Не писать comparison with Guidance/Outlines.
- Не писать paper plots.
- Не делать tutorial на 50 страниц.

## Public interfaces / touched interfaces

Examples должны импортировать только публичный API:

```racket
(require rack-llm)
```

## Scientific / design notes

Документация должна показывать красивую маленькую библиотеку: `Guide[A]`, `text`, `rank`, `ban`, `bind`. Не надо продавать зоопарк функций, которого нет.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Каждый example запускается `racket examples/name.rkt`.
- Docs не упоминают удаленные `need/must/cap/calc/emit/accept-score` как актуальные.
- Code snippets в docs синтаксически корректны.

## Integration tests

- Один smoke-test запускает все examples.
- `raco test` проходит.

## Definition of Done

- [x] 4 examples есть и работают.
- [x] Docs достаточно, чтобы новый разработчик понял API за 15 минут.
- [x] Нет экспериментальных датасетов/раннеров.

## Status

Done.

## Result

- Added four public examples under `examples/`, each using only `(require rack-llm)`.
- Added `docs/design.md`.
- Added `make examples` and included it in `make ci`.
- Verified with `make ci`.
