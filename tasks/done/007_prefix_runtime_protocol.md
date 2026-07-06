# Реализовать prefix runtime protocol для Guide

Status: done

## SMART goal

За 3 рабочих дня заменить проверку полного текста на каждом токене протоколом префиксного состояния.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

- Ввести runtime state interface для guide:
  - `init-state`
  - `step-state`
  - `finish-state`
  - `dead?`
  - `done?`
  - `state-score`
  - `state-potential`
  - `state-value`
  - `state-trace`
- Старый `parse-guide/check` можно оставить временно, но `generate` должен использовать prefix runtime.
- Состояние должно различать “префикс еще не завершен” и “ветка мертва”.

## Out of scope

- Не нужно реализовывать все guide kinds в этой задаче; достаточно protocol и skeleton.
- Не делать полноценные DFA-оптимизации.

## Public interfaces / touched interfaces

Возможная форма:

```racket
(struct rt-state (kind data score potential trace) #:transparent)
(guide-init guide) -> rt-state
(guide-step state token) -> rt-state
(guide-finish state) -> rt-state
```

## Scientific / design notes

Это главный технический переход. Текущий подход `check(prefix)` путает viable-prefix и accepted-string. Для hard generation это смертельно, как обычно бывает, когда “еще не готово” принимают за “сломано”.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Для `(seq "A" "B")` состояние после токена `"A"` не dead, но не done.
- После `"AB"` done true.
- После `"AC"` dead true.
- `finish` незавершенного hard-state возвращает dead или not done по выбранной семантике.

## Integration tests

- Минимальный `generate` на `(seq "A" "B")` проходит через prefix states, а не через full check.
- Debug trace показывает последовательность states.

## Definition of Done

- [x] Prefix protocol реализован.
- [x] `generate` больше не вызывает `check` для каждого префикса как единственный способ жизнеспособности.
- [x] Есть документация `docs/runtime.md`.

## Result

Добавлены `rt-state`, `guide-init`, `guide-step`, `guide-finish`, `dead?`,
`done?` и accessors состояния. Open decoding теперь продвигает prefix state
по токенам. Добавлена документация `docs/runtime.md` и тесты live/done/dead
для `(seq "A" "B")`.
