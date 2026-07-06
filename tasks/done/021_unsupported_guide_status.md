# Задача 021. Добавить режим `unsupported-guide-for-sampling` вместо slow fallback

Исходный номер в `tasks.md`: 022.


## SMART goal

За 1 рабочий день убрать опасный slow fallback из production generation: если guide не имеет prefix-runtime, генерация должна явно отказаться, а не тихо перейти к `check`-на-каждом-токене.

## Scope

В задаче:

* добавить predicate:

  ```racket
  sampling-supported?
  ```
* если unsupported:

  ```racket
  generation-result-status = 'unsupported-guide-for-sampling
  ```
* режим dev может бросать exception;
* `check` остается доступным для post-hoc validation.

## Out of scope

Не входит:

* реализация недостающих runtimes;
* experiment handling.

## Unit tests

Создать fake guide kind `'unknown`.

`generate` должен вернуть unsupported, а не зависнуть и не вызвать `check` в loop.

## DoD

* [x] Slow fallback удален из production sampling.
* [x] Unsupported guide возвращает явный статус.
* [x] Metrics показывает причину.
* [x] README обновлен.

---
