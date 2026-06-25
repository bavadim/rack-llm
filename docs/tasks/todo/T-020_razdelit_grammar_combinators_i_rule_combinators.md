# T-020. Разделить grammar combinators и rule combinators

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 2 рабочих дня

### SMART goal

Развести два разных понятия: grammar combinators управляют допустимыми строками, rule combinators агрегируют проверки готовых результатов. В API и документации не должно быть путаницы между `one_or_more(expr)` и `at_least(k, rules)`.

### В скоупе

- Создать `grammar/combinators.rkt`.
- Создать stub `rules/combinators.rkt` для будущих rule combinators.
- Обновить docs с таблицей различий.

### Не в скоупе

- Реализация всех комбинаторов.
- Новый matcher.

### Публичные интерфейсы

```racket
(require rack-llm/grammar/combinators)
(require rack-llm/rules/combinators)
```

### Implementation notes

В docs прямо написать:

```text
one_or_more(g)  -> grammar repetition
at_least(k, rs) -> rule aggregation
```

В публичном API не должно появляться имя `at_least_ones`; для повторений используется `one-or-more`, для правил — `rule-at-least`.

### Unit tests

Smoke compile:

```racket
(check-true (procedure? one-or-more))
(check-true (procedure? rule-at-least))
```

### Integration tests

- Docs example imports both modules without name conflict.

### Definition of Done (DoD)

- Названия разведены.
- В документации есть раздел `Grammar vs rules`.
- Нет публичного имени `at_least_ones`.

---
