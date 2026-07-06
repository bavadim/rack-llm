# Реализовать core-типы и log-score семантику

Status: done

## SMART goal

За 2 рабочих дня привести внутренние структуры к единой модели `Guide[A] = string + value + log-score`.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

- Определить структуры `guide`, `watch`, `ranked`, `banned`, `generation-result`, `check-result`.
- Ввести константу `neg-inf = -inf.0`.
- Ввести helper'ы для сложения score, сравнения score, проверки `-inf`.
- Зафиксировать, что hard mismatch = `-inf`, neutral = `0`, soft preference = конечный вес.
- Сохранить `ranked` как отложенную аннотацию, а не как guide/watch напрямую.

## Out of scope

- Не реализовывать полный runtime.
- Не реализовывать EM.
- Не менять провайдеры.

## Public interfaces / touched interfaces

Ожидаемые структуры:

```racket
(struct guide (kind data) #:transparent)
(struct watch (kind data) #:transparent)
(struct ranked (score expr) #:transparent)
(struct banned (expr) #:transparent)
```

И helper'ы:

```racket
(log-score-add a b)
(log-score-dead? x)
```

## Scientific / design notes

Единый log-score позволяет без отдельного `accept score` объединить hard guidance и soft ranking. Это делает API научно чище и практически проще.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `log-score-add` с `-inf.0` возвращает `-inf.0`.
- `(rank 2 "yes")` возвращает `ranked`, а не `guide`.
- `banned?` работает для `(ban ...)`.
- Неверный вес в `rank` дает понятную ошибку.

## Integration tests

- Старые простые examples `lit/rx/seq/select/text` создают структуры без падения.
- `check` может временно оставаться старым, но должен принимать новые структуры через адаптеры.

## Definition of Done

- [x] Все core-типы находятся в одном модуле.
- [x] Semantics documented in comments.
- [x] Public predicates экспортированы только для полезной отладки: `guide?`, `watch?`, `ranked?`, `banned?`.
- [x] Нет старого `ok?`-only результата как единственного состояния.

## Result

Добавлены `watch`, `neg-inf`, `log-score-add`, `log-score-dead?`,
`log-score>?`; runtime и sampling используют log-score helper для сложения.
Публичная документация и тесты обновлены.
