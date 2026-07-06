# Задача 018. Реализовать `potential` для literal/rank watchers

Исходный номер в `tasks.md`: 015.


## SMART goal

За 2 рабочих дня реализовать простой potential для строковых и regex-like watchers, чтобы soft-наблюдатели влияли до полного match.

## Scope

В задаче:

* для literal/string watcher считать прогресс по KMP-like prefix;
* для простых regex использовать грубый potential:

  * literal substring внутри regex;
  * или 0, если не извлекается literal core;
* potential должен быть конечным числом;
* `rank` с положительным весом увеличивает potential при приближении;
* `rank` с отрицательным весом уменьшает potential при приближении.

## Out of scope

Не входит:

* полный regex-to-DFA;
* probabilistic future oracle;
* learned potential.

## Unit tests

Watcher:

```racket
(rank 3 "patent")
```

Проверить:

```text
""      potential low
"pa"    potential higher
"pate"  potential higher
"patent" score +3
```

## DoD

* [x] `state-potential` не всегда 0 для rank watchers.
* [x] `lambda` в sampling реально меняет adjusted logits.
* [x] Есть тест, где potential повышает вероятность completion на mock provider.

---
