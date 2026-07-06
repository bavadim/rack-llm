# Задача 019. Интегрировать `weight` в инкрементальные watchers

Исходный номер в `tasks.md`: 016.


## SMART goal

За 2 рабочих дня сделать `weight` не только post-hoc scorer, но и инкрементальный watcher внутри `text`.

## Scope

В задаче:

* `weighted-watch-state` хранит состояния всех внутренних watchers;
* score — сумма весов сработавших rules;
* one-shot saturation для каждого внутреннего rule;
* trace показывает:

  * expr;
  * learned weight;
  * pos-prob;
  * neg-prob.

## Out of scope

Не входит:

* переписывание EM;
* supervised training;
* correlation-aware label model.

## Unit tests

Создать synthetic calibration data:

```text
good: contains "source"
bad: contains "unknown"
```

Проверить, что `weight` дает положительный вес `source` и отрицательный `unknown`.

Проверить в `text`, что score меняется инкрементально.

## DoD

* [x] `weight` работает внутри `text` в generation runtime.
* [x] Нет полного `watcher-score` по whole text в token loop.
* [x] Trace содержит learned weights.
* [x] Synthetic EM test проходит.

---
