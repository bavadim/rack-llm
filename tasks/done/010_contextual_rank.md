# Реализовать контекстную интерпретацию `rank`

Status: done

## SMART goal

За 2 рабочих дня сделать `rank` единым публичным оператором, который в closed context ранжирует guide, а внутри `text` становится watcher.

## Dependencies

Зависит от `003_core_types_and_log_score.md`, `008_closed_guides_runtime.md`, `009_text_and_watch_runtime.md`.

## Scope

- `rank` возвращает `ranked`, не `guide` и не `watch` напрямую.
- Реализовать `->guide`: `ranked` превращается в закрытый guide с бонусом.
- Реализовать `->watch`: `ranked` превращается в watcher для `text`.
- `select/seq/repeat/json` используют `->guide`.
- `text` использует `->watch`.
- Ошибочные контексты дают понятные ошибки.

## Out of scope

- Не делать настоящую перегрузку через макросы.
- Не делать context-dependent behavior, которое невозможно объяснить.
- Не открывать мир в `rank`.

## Public interfaces / touched interfaces

Примеры:

```racket
(select (rank 2 "yes") "no") ; only yes/no, yes +2
(text (rank 3 (rx #px"patent"))) ; any text, patent +3
```

## Scientific / design notes

Один `rank` в API сохраняет простоту, но внутри типы разные. Родительский контекст выполняет elaboration. Это дешевле и чище, чем два публичных оператора `prefer/watch`.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `(rank 2 "yes")` сам по себе не является guide.
- `(select (rank 2 "yes") "no")` допускает только yes/no.
- `(text (rank 2 "yes"))` допускает любой текст и добавляет score при contains yes.
- `(select (ban ...))` должен выдавать ошибку: ban не guide.

## Integration tests

- `generate` с ranked select предпочитает ranked alternative при равных logits.
- `generate` с ranked text повышает вероятность паттерна относительно beta=0 на mock provider.

## Definition of Done

- [x] Контекстная интерпретация реализована без макросов.
- [x] Документировано, что `rank` не открывает мир.
- [x] Ошибки контекста понятны джуниору, а это редкая роскошь.

## Result

Closed contexts now elaborate strings/guides/ranked values through
`ensure-guide`; `text` elaborates ranked/banned/watch values through
`ensure-watch`. `select (ban ...)` fails immediately with a contextual error.
Added generation tests for ranked closed choice and ranked open text.
