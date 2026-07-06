# Задача 020. Ограничить `finite-candidates` и убрать его из production sampling

Исходный номер в `tasks.md`: 021.


## SMART goal

За 1 рабочий день сделать `finite-candidates` безопасным: оно не должно взрывать память и не должно использоваться в production sampling без лимита.

## Scope

В задаче:

* добавить лимит:

  ```racket
  #:max-finite-candidates
  ```
* если кандидатов больше лимита, вернуть marker:

  ```racket
  'too-many
  ```
* `generate` не должен автоматически перечислять огромный finite guide;
* small finite guides можно по-прежнему решать через `best-finite`.

## Out of scope

Не входит:

* trie runtime;
* smarter enumeration;
* exact sorting.

## Unit tests

Guide:

```racket
(repeat 0 20 (select "A" "B" "C"))
```

Должен превысить лимит и не перечисляться полностью.

## DoD

* [x] `finite-candidates` имеет лимит.
* [x] Huge finite guide не вызывает memory blowup.
* [x] Small finite guide по-прежнему работает.
* [x] Sampling не делает hidden exponential enumeration.

---
