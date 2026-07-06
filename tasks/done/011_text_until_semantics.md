# Задача 011. Переработать или временно отключить `text #:until`

Исходный номер в `tasks.md`: 010.


## SMART goal

За 1 рабочий день убрать некорректную текущую семантику `#:until` из production path: либо реализовать понятный `text-until`, либо пометить `#:until` как unsupported для sampling.

## Scope

В задаче выбрать один вариант.

### Вариант A: временно отключить

Если `text` содержит `#:until`, `generate` возвращает:

```racket
'unsupported-guide-for-sampling
```

а `check` может продолжать работать post-hoc.

### Вариант B: реализовать `text-until`

Добавить отдельный guide:

```racket
(text-until delimiter watcher ...)
```

Семантика: `text` потребляет токены до delimiter, delimiter не включается в text и должен потребляться следующим guide.

## Out of scope

Не входит:

* arbitrary lookahead parser;
* nested delimiters;
* backtracking.

## DoD

* [x] Текущий `#:until` больше не дает ложных dead/live состояний.
* [x] В README обновлена семантика.
* [x] Есть тест:

  ```racket
  (seq "A" (text-until "END") "END")
  ```

  если выбран вариант B.
* [x] Если выбран вариант A, есть тест на понятную ошибку unsupported.

---
