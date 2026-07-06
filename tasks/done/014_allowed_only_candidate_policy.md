# Задача 014. Добавить candidate policy `allowed-only`

Исходный номер в `tasks.md`: 011.


## SMART goal

За 2 рабочих дня добавить режим генерации, в котором closed finite guides могут отдавать маленький список допустимых token ids, и sampler не сканирует весь словарь.

## Scope

В задаче:

* добавить параметр:

  ```racket
  #:candidate-policy 'allowed-only
  ```
* runtime state может вернуть:

  ```racket
  allowed-next-ids
  ```
* если список ids есть, sampler рассматривает только их;
* если список `#f`, fallback на full-vocab или top-k policy.

## Out of scope

Не входит:

* top-k+watch;
* llama.cpp session;
* full regex DFA.

## Unit tests

Guide:

```racket
(select "yes" "no")
```

С vocab 50k токенов убедиться, что число рассмотренных токенов на шаге ≤ 2 или равно числу trie children.

## DoD

* [x] `allowed-only` не сканирует весь vocab для finite select.
* [x] Metrics содержит `candidate-count`.
* [x] Hard guide не возвращает токен вне allowed ids.
* [x] Fallback явно документирован.

---
