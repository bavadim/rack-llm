# Удалить legacy-остатки и заморозить API v1

## SMART goal

За 1 рабочий день удалить лишние старые операторы и зафиксировать экспортируемый API v1.

## Dependencies

Зависит от завершения всех implementation tasks.

## Scope

- Удалить или не экспортировать устаревшие сущности: `gen`, `capture`, `calc`, `emit`, `need`, `must`, `accept-score`, старые artifact acceptance/resampling modules, если они есть.
- Проверить `(provide ...)`.
- Добавить тест, который сравнивает exported symbols с allowlist.
- Добавить `CHANGELOG.md` с записью о breaking change.

## Out of scope

- Не удалять внутренние helper'ы, если они не экспортируются и нужны.
- Не поддерживать обратную совместимость ценой усложнения API.
- Не добавлять migration layer.

## Public interfaces / touched interfaces

Allowlist:

```racket
lit rx seq select repeat text rank ban weight pure bind
make-provider make-mock-provider generate generate-stream check
;; predicates/result structs as documented
```

## Scientific / design notes

Мы специально не тащим старую схему в новый core. Совместимость — прекрасное слово, которым часто называют отказ когда-либо закончить рефакторинг.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Экспортируемые имена совпадают с allowlist.
- Попытка импортировать удаленный оператор из public API падает.
- Все examples используют только v1 API.

## Integration tests

- `raco test` проходит.
- `docs/api.md` совпадает с public exports.

## Definition of Done

- [x] Legacy API не экспортируется.
- [x] API v1 зафиксирован в docs и тестах.
- [x] В библиотеке нет experiment/dataset runner code.

## Status

Done.

## Result

- Added a public `rack-llm` export allowlist test.
- Added tests that removed legacy operators cannot be imported.
- Added checks that examples import only `(require rack-llm)`.
- Added `CHANGELOG.md` with the v1 breaking-change note.
- Verified with `make ci`.
