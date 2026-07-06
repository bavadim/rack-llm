# Задача 004. Реализовать prefix-runtime для `lit`

Исходный номер в `tasks.md`: 003.


## SMART goal

За 1 рабочий день реализовать инкрементальное состояние для `lit`, чтобы фиксированные строки проверялись и fast-forward’ились без полного `check`.

## Scope

В задаче:

* состояние `lit` хранит literal и offset;
* `step` проверяет, продолжает ли token literal;
* `done?` true, если literal полностью пройден;
* `dead?` true, если token не совпал с ожидаемым continuation;
* реализовать forced/fast-forward информацию для deterministic path.

## Out of scope

Не входит:

* trie для `select`;
* токенизация literal в несколько token ids;
* `json`.

## State

```racket
(struct lit-state
  (literal offset status score potential value trace)
  #:transparent)
```

## Unit tests

```racket
(lit "Answer: ")
```

Проверить:

* пустое состояние `live`;
* после `"Ans"` состояние `live`;
* после полного literal состояние `done`;
* после неправильного токена состояние `dead`.

## Integration tests

Guide:

```racket
(seq "Answer: " (select "yes" "no"))
```

Проверить, что fixed prefix `"Answer: "` вставляется без LLM-вызовов, если fast-forward включен.

## DoD

* [x] `lit` не вызывает `check` в `step`.
* [x] `lit` умеет отличать `live`, `done`, `dead`.
* [x] `lit` возвращает forced continuation, если следующий фрагмент детерминирован.
* [x] Есть unit tests на prefix/live/done/dead.

---
