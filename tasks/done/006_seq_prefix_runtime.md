# Задача 006. Реализовать prefix-runtime для `seq`

Исходный номер в `tasks.md`: 005.


## SMART goal

За 2 рабочих дня реализовать последовательное исполнение guide-элементов через состояние текущего child, без повторной проверки всего `seq`.

## Scope

В задаче:

* `seq-state` хранит индекс текущего элемента;
* после `done?` child переходит к следующему;
* score складывается;
* value возвращает значение последнего значимого child;
* dead child делает весь `seq` dead.

## Out of scope

Не входит:

* сложное неоднозначное разбиение строки;
* backtracking между несколькими child;
* `text #:until`.

## State

```racket
(struct seq-state
  (children index child-state score value trace)
  #:transparent)
```

## Unit tests

Guide:

```racket
(seq "A" "B" "C")
```

Проверить переходы:

* after `"A"` index = 1;
* after `"AB"` index = 2;
* after `"ABC"` done;
* `"AX"` dead.

## Integration tests

Guide:

```racket
(seq "Answer: " (select "yes" "no"))
```

С mock provider, где high logit у `"maybe"`, результат должен быть `Answer: yes/no`.

## DoD

* [x] `seq` не вызывает `check` или `finite-candidates` в `step`.
* [x] `seq` корректно передает управление между children.
* [x] `seq` складывает scores.
* [x] Есть tests для live/done/dead.

---
