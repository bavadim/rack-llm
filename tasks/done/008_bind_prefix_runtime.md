# Задача 008. Реализовать prefix-runtime для `bind`

Исходный номер в `tasks.md`: 007.


## SMART goal

За 2 рабочих дня реализовать `bind` как двухфазное состояние: сначала исполняется первый guide, затем continuation создается один раз по value и исполняется как второй guide.

## Scope

В задаче:

* `bind-state` хранит phase:

  ```racket
  'first
  'cont
  ```
* при `done?` первого guide вызвать continuation;
* continuation нельзя пересоздавать на каждом token;
* value итогового состояния — value continuation.

## Out of scope

Не входит:

* backtracking по нескольким значениям первого guide;
* bind внутри `text` watchers;
* произвольное переисполнение continuation.

## Unit tests

Guide:

```racket
(bind (select "A" "B")
      (lambda (x) (seq "-" x)))
```

Проверить:

* `"A-A"` валидно;
* `"B-B"` валидно;
* `"A-B"` dead/invalid.

## DoD

* [x] Continuation вызывается ровно один раз на выбранное значение.
* [x] Нет пересоздания continuation в каждом `step`.
* [x] `bind` работает с `seq/select/lit`.
* [x] Tests покрывают зависимый шаблон.

---
