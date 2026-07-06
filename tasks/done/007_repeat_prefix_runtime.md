# Задача 007. Реализовать prefix-runtime для `repeat`

Исходный номер в `tasks.md`: 006.


## SMART goal

За 2 рабочих дня реализовать bounded repeat через состояние счетчика и текущего item-state, без полного перечисления всех повторов.

## Scope

В задаче:

* поддержать:

  ```racket
  (repeat min max guide)
  ```
* хранить `count`, `item-state`, accumulated values, accumulated score;
* `done?` true при `count >= min` и допустимом завершении;
* продолжение возможно пока `count < max`;
* zero-length item должен быть запрещен или явно обработан.

## Out of scope

Не входит:

* unbounded repeat;
* произвольный backtracking;
* regex-style greedy/lazy режимы.

## Unit tests

```racket
(repeat 2 3 "A")
```

Проверить:

* после одного `"A"` live, not done;
* после двух `"A"` done and live;
* после трех `"A"` done and cannot continue;
* четвертый `"A"` dead.

## DoD

* [x] `repeat` не перечисляет все варианты.
* [x] Есть защита от zero-length infinite loops.
* [x] Правильно работает min/max.
* [x] Score повторов складывается.

---
