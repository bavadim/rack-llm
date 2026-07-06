# Реализовать `text` как единственный open-world сегмент

Status: done

## SMART goal

За 3 рабочих дня реализовать `text` runtime и тип `Watch`, чтобы открытый текст можно было ранжировать и запрещать без превращения всего DSL в хаос.

## Dependencies

Зависит от `007_prefix_runtime_protocol.md`, желательно после `008_closed_guides_runtime.md`.

## Scope

- `text` генерирует произвольную строку до `max-tokens`, stop/until или внешнего завершения.
- Внутри `text` разрешены только watches: `ranked` и `banned` после контекстного приведения.
- Watcher несовпадение не убивает строку.
- Watcher совпадение добавляет score.
- `text` должен возвращать generated string как value.
- `text` должен иметь `finish` для финального начисления score и trace.

## Out of scope

- Не делать arbitrary callbacks.
- Не делать `text` внутри `select` открытой альтернативой без явного guide.
- Не добавлять external verifiers.

## Public interfaces / touched interfaces

```racket
(text (rank 3 (rx #px"patent"))
      (rank -5 (rx #px"TODO"))
      (ban (rx #px"secret"))) -> Guide[String]
```

## Scientific / design notes

Open-world нужен только в `text`. Это практично: жесткие шаблоны остаются строгими, а свободные области получают наблюдателей с score. Так не ломается `select`.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `text` без watchers принимает любую строку в пределах лимита.
- `rank` внутри `text` начисляет score при match.
- `rank` negative уменьшает score.
- `ban` внутри `text` делает state dead при match.
- Несовпадение watcher не делает dead.

## Integration tests

- `generate` с `text` возвращает `found` при отсутствии hard ban.
- `text` с `ban` не возвращает строку с запрещенным паттерном, если provider предлагает альтернативы.

## Definition of Done

- [x] `text` реализован как единственный open-world segment.
- [x] `Watch`-семантика покрыта тестами.
- [x] Trace содержит matched watchers и scores.

## Result

`text` runtime теперь обрабатывает budget, watcher score, hard ban и trace
для matched watchers. Добавлены тесты на open-world text, positive/negative
rank, ban и watcher mismatch.
