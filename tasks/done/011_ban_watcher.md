# Реализовать `ban` как hard veto для открытого текста

Status: done

## SMART goal

За 1 рабочий день сделать `ban` отдельным жестким запретом внутри `text`, не заменяемым магическими большими отрицательными весами.

## Dependencies

Зависит от `009_text_and_watch_runtime.md`.

## Scope

- `ban expr` возвращает `banned`.
- `text` превращает `banned` в watcher с hard-dead при match.
- `ban` должен поддерживать минимум `lit`, `rx`, string.
- Trace должен фиксировать, какой ban сработал.
- `ban` вне `text` должен либо быть ошибкой, либо явно конвертироваться только в поддержанных контекстах. Для v1 лучше ошибка вне `text`.

## Out of scope

- Не поддерживать arbitrary guide с bind внутри ban.
- Не делать ban как `rank -1e9`.
- Не делать внешние проверки.

## Public interfaces / touched interfaces

```racket
(text (ban (rx #px"TODO|\[citation needed\]")))
```

## Scientific / design notes

Hard-veto нужен отдельно: запрещенные паттерны должны обрезаться сразу и не зависеть от beta/temperature. Иначе “секретный токен почти не сгенерировался” станет нормальным инженерным аргументом, а мир и так уже держится на скотче.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Строка с banned pattern не проходит `check`.
- Prefix runtime становится dead сразу после match.
- Строка без banned pattern проходит.
- Trace содержит ban failure.

## Integration tests

- `generate` не возвращает banned pattern в `found`, если есть альтернативные токены.
- Если provider вынуждает banned pattern, результат `not-found-hard` или `not-found-budget`.

## Definition of Done

- [x] `ban` реализован.
- [x] Negative hard semantics не зависят от beta.
- [x] Unit tests покрывают lit/rx/string ban.

## Result

`ban` остается delayed `banned`, `text` интерпретирует его как hard veto.
Добавлены тесты на string/lit/rx ban, trace, beta-independence и forced-ban
provider failure.
