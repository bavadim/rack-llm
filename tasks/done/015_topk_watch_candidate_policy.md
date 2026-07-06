# Задача 015. Добавить candidate policy `top-k+watch`

Исходный номер в `tasks.md`: 012.


## SMART goal

За 3 рабочих дня добавить приближенный production-режим для soft `text`: sampler рассматривает top-K токены LLM плюс watched tokens от активных watchers.

## Scope

В задаче:

* добавить параметр:

  ```racket
  #:candidate-policy '(top-k+watch 64)
  ```
* provider должен уметь вернуть top-K ids из logits vector;
* watchers должны вернуть watched ids или watched token strings;
* candidate set:
  [
  C = TopK \cup WatchIds
  ]
* full-vocab не сканируется в этом режиме.

## Out of scope

Не входит:

* строгие hard guarantees для всех regex;
* сложные watched sets для arbitrary regex;
* exact probability normalization.

## Unit tests

Сделать watcher, чей watched token не входит в top-K. Проверить, что он добавлен в candidate set.

## Integration tests

Guide:

```racket
(text (rank 3 (rx #px"patent")))
```

С mock logits, где `patent` не top-1, но watched, проверить, что при `beta` score может вытянуть `patent`.

## DoD

* [x] `top-k+watch` не сканирует весь vocab.
* [x] `candidate-count <= K + W`.
* [x] Metrics пишет `candidate-policy`.
* [x] README предупреждает, что режим приближенный.

---
