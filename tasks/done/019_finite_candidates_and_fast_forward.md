# Сохранить finite candidates и добавить fast-forward для детерминированных фрагментов

Status: done

## SMART goal

За 3 рабочих дня восстановить/обновить finite enumeration для конечных guide и добавить fast-forward fixed literals, не ломая prefix runtime.

## Dependencies

Зависит от `006`, `008`, `010`, `012`.

## Scope

- `finite-candidates` должен работать для `pure`, `lit`, finite `select`, finite `seq`, bounded `repeat`, `rank` in closed context, `bind` если first finite.
- Для finite guide `generate` может выбрать лучший candidate без токенного loop.
- `lit` должен поддерживать fast-forward: фиксированный текст вставляется без LLM calls, если текущий active guide детерминирован.
- Считать lm-logprob для fast-forward фрагмента через provider, если нужно total-score.

## Out of scope

- Не перечислять `text` как finite.
- Не пытаться перечислять regex с бесконечным языком.
- Не реализовывать exact sorted infinite iterator.

## Public interfaces / touched interfaces

```racket
(finite-candidates guide) -> list or #f
(fast-forward-state state provider prompt prefix) -> state/prefix/lm-logprob
```

## Scientific / design notes

Finite enumeration важен для closed `select` и маленьких шаблонов. Fast-forward снижает число LLM вызовов на литералах, как принято в structured generation библиотеках.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `finite-candidates` для `(select "yes" "no")` возвращает 2.
- Ranked finite branch сохраняет score.
- `text` возвращает non-finite.
- Fast-forward literal не вызывает provider-next-logits для выбора токена, но при включенном score считает logprob корректно.

## Integration tests

- `generate` на конечном select выбирает candidate по `lm + beta*score`.
- Шаблон с длинным literal делает меньше LLM calls, чем посимвольное декодирование.

## Definition of Done

- [x] Finite candidates работают после рефакторинга.
- [x] Fast-forward реализован и покрыт тестами.
- [x] Нет попыток построить бесконечный список строк, потому что мы все еще ценим оперативную память.

## Result

`finite-candidates` теперь публично возвращает список для finite guide и `#f`
для open/infinite guide. Добавлен `fast-forward-state` для deterministic
literals с optional LM scoring. Добавлены тесты finite select/rank/text и
fast-forward без provider calls для token choice.
