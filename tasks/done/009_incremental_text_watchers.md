# Задача 009. Реализовать инкрементальные watchers для `text`

Исходный номер в `tasks.md`: 008.


## SMART goal

За 3 рабочих дня заменить `watcher-score watchers full-text` в token loop на инкрементальные watcher states, чтобы soft `text` не пересканировал весь текст для каждого токена.

## Scope

В задаче:

* ввести `WatchRuntimeState`;
* реализовать `rank` watcher:

  * `lit` / string;
  * простое `rx`;
* реализовать `ban` watcher;
* score должен начисляться one-shot по умолчанию;
* trace должен фиксировать первое срабатывание.

## Out of scope

Не входит:

* full PCRE automata;
* repeated/counting rewards;
* EM `weight` watcher, он отдельной задачей.

## Internal API

```racket
watch-init      : Watch -> WatchState
watch-step      : WatchState TokenString -> WatchState
watch-dead?     : WatchState -> Boolean
watch-score     : WatchState -> Real
watch-potential : WatchState -> Real
watch-trace     : WatchState -> Trace
```

## Unit tests

```racket
(text
  (rank 3 (rx #px"patent"))
  (ban (rx #px"TODO")))
```

Проверить:

* после `patent` score +3;
* повторный `patent` не добавляет еще +3;
* после `TODO` state dead;
* text без matches живой и score 0.

## DoD

* [x] `text` watcher score не пересчитывается по полному тексту в token loop.
* [x] `rank` работает one-shot.
* [x] `ban` делает dead immediately.
* [x] Есть trace с matched watcher.

---
