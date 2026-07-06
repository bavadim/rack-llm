# Переписать `check` поверх того же runtime, что и `generate`

Status: done

## SMART goal

За 2 рабочих дня сделать `check` единым валидатором для hard и soft guide, возвращающим trace и score.

## Dependencies

Зависит от `008`, `009`, `010`, `011`, `012`.

## Scope

- `check` должен использовать runtime/parse семантику, согласованную с `generate`.
- Вернуть расширенный `check-result`: `ok?`, `value`, `guide-score`, `hard-ok?`, `trace`, `failures`, `matched-watchers`.
- `check` должен поддерживать `text` watchers, `rank`, `ban`, `bind`.
- Для hard guide `ok?` означает принадлежность hard-языку.
- Для soft `text` `ok?` обычно true, если нет ban/failures.

## Out of scope

- Не вызывать external gold verifiers.
- Не писать датасетную классификацию `FOUND_OK`.
- Не делать approximate check.

## Public interfaces / touched interfaces

```racket
(check guide "some text") -> check-result
```

## Scientific / design notes

`check` — это библиотечная гарантия. В hard-mode `generate(found)` обязан проходить `check`. В soft-mode `check` нужен для score, trace и return policy.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `check` closed seq/select корректен.
- `check` text rank начисляет score.
- `check` text ban отклоняет строку.
- `check` bind с динамическим последующим guide работает.
- Trace имеет стабильную структуру.

## Integration tests

- Все generated `found` результаты проходят `check`.
- `check` и `generate` дают одинаковый guide-score на одинаковом тексте.

## Definition of Done

- [x] Старый `check-result` заменен расширенным.
- [x] Trace и failures доступны.
- [x] Hard-valid invariant покрыт integration test.

## Result

`check-result` расширен полями `hard-ok?`, `trace`, `failures`,
`matched-watchers`. `check` возвращает стабильный trace для watcher matches и
failure trace для hard ban/mismatch. Добавлены тесты на expanded result API и
invariant `generate(found) => check.ok?` с совпадающим guide-score.
