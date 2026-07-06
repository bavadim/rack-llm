# Задача 016. Подключить fast-forward для deterministic fragments

Исходный номер в `tasks.md`: 013.


## SMART goal

За 2 рабочих дня сделать так, чтобы фиксированные фрагменты `lit` и однозначные части `seq` вставлялись без вызова LLM и без full-vocab scan.

## Scope

В задаче:

* реализовать:

  ```racket
  fast-forward-state : RuntimeState Provider -> RuntimeState
  ```
* вызывать fast-forward перед каждым запросом logits;
* обновлять text, state, token-count, metrics;
* logprob для fast-forward можно считать отдельно или помечать как deterministic.

## Out of scope

Не входит:

* fast-forward для regex;
* forced decoding через provider;
* сложный lookahead.

## Unit tests

Guide:

```racket
(seq "Answer: " (select "yes" "no"))
```

Проверить, что до `select` нет provider calls.

## DoD

* [x] `lit` вставляется без LLM-вызова.
* [x] Metrics содержит `fast-forward-tokens`.
* [x] Результат проходит `check`.
* [x] Speed test показывает меньше provider calls на fixed-prefix guide.

---
