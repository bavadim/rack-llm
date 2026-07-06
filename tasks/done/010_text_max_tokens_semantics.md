# Задача 010. Исправить семантику `text #:max-tokens`

Исходный номер в `tasks.md`: 009.


## SMART goal

За 1 рабочий день заменить использование `string-length` как token budget на реальный счетчик токенов text-сегмента.

## Scope

В задаче:

* `text-state` хранит `token-count`;
* `#:max-tokens` сравнивается с token-count;
* если нужен char limit, добавить отдельный `#:max-chars`, но не использовать его вместо tokens.

## Out of scope

Не входит:

* semantic stop conditions;
* `#:until`.

## Unit tests

С provider vocab:

```racket
'("hello" "world" "!")
```

`(text #:max-tokens 2)` должен завершаться после двух выбранных токенов, независимо от длины строк.

## DoD

* [x] `#:max-tokens` работает по токенам.
* [x] Тест с длинными token strings проходит.
* [x] Старые тесты не ломаются.

---
