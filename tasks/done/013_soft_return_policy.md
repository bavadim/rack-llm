# Задача 013. Реализовать return-policy для soft abstention

Исходный номер в `tasks.md`: 018.


## SMART goal

За 1 рабочий день реализовать runtime return-policy, которая превращает низкий soft-score в `not-found-low-score`, не добавляя `accept score` в DSL.

## Scope

В задаче:

* поддержать:

  ```racket
  'always
  (min-guide-score τ)
  (min-total-score τ)
  ```
* policy применяется после генерации candidate или best-of candidates;
* если policy не пройдена, статус `not-found-low-score`.

## Out of scope

Не входит:

* risk-target на dev-set;
* external verifier;
* IFBench wrappers.

## Unit tests

Guide:

```racket
(text (rank 3 "patent"))
```

Если сгенерирован текст без patent:

* `'always` → `found`;
* `(min-guide-score 3)` → `not-found-low-score`.

## DoD

* [x] Return-policy работает после `keep-best`.
* [x] Soft-only может abstain только через policy.
* [x] Hard-only unaffected.
* [x] Tests проходят.

---
