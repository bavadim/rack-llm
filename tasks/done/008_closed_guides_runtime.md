# Реализовать runtime для закрытых guide-комбинаторов

Status: done

## SMART goal

За 4 рабочих дня реализовать prefix runtime для `lit`, `rx`, `seq`, `select`, `repeat` в closed-world семантике.

## Dependencies

Зависит от `007_prefix_runtime_protocol.md`.

## Scope

- `lit`: префиксная проверка фиксированной строки, fast-forward compatible.
- `rx`: префиксная жизнеспособность regex; для v1 можно начать с bounded/full-match strategy, но поведение должно быть корректно на тестах.
- `seq`: активный дочерний guide, передача value последнего значимого guide.
- `select`: альтернатива viable, если viable хотя бы одна ветка; score = max branch score.
- `repeat`: min/max повторения, запрет infinite zero-width loop.
- Все closed guides возвращают score `0` на допустимых строках и `-inf` на недопустимых, если нет `rank`.

## Out of scope

- Не реализовывать `text` watchers.
- Не оптимизировать regex через DFA, если это мешает завершить задачу. Но интерфейс должен позволять заменить реализацию позже.

## Public interfaces / touched interfaces

Должны работать:

```racket
(lit "abc")
(rx #px"[0-9]+")
(seq (lit "A") (select "B" "C"))
(repeat 1 3 (rx #px"[a-z]"))
```

## Scientific / design notes

Closed-world слой нужен, чтобы библиотека была не хуже guidance-style генерации в структурных задачах. Это основа, на которой потом живут soft-наблюдатели.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Unit-тесты на viable/done/dead для каждого комбинатора.
- `(select "yes" "no")` не допускает `"maybe"`.
- `repeat` не зависает на guide, который может породить пустую строку.
- `rx` full-check совпадает с `check` на завершенных строках.

## Integration tests

- `generate` на конечных closed guides возвращает hard-valid строки.
- `check` и runtime согласованы на наборе строк.

## Definition of Done

- [x] Closed guide runtime реализован.
- [x] Все указанные комбинаторы покрыты тестами.
- [x] Hard-valid invariant выполняется: `status='found => check.ok?`.

## Result

Prefix runtime теперь имеет закрытую dispatch-семантику для `lit`, `rx`,
`seq`, `select`, `repeat`; добавлены тесты viable/done/dead для каждого
комбинатора и invariant для generated closed result.
