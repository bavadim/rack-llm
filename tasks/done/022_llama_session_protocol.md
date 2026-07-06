# Задача 022. Перевести llama.cpp bridge на session protocol

Исходный номер в `tasks.md`: 020.


## SMART goal

За 3 рабочих дня добавить stateful llama.cpp session API, чтобы sidecar не пересчитывал `prompt + prefix` с нуля на каждом шаге.

## Scope

В задаче:

* добавить optional provider session protocol:

  ```racket
  provider-start-session
  provider-next-logits/session
  provider-commit-token!
  provider-end-session!
  ```
* обновить `llama-cpp.rkt` под команды:

  ```json
  {"op":"start","prompt":"..."}
  {"op":"next_logits"}
  {"op":"commit","token_id":123}
  {"op":"end"}
  ```
* сохранить старый stateless protocol как fallback.

## Out of scope

Не входит:

* реализация C++ sidecar;
* KV-cache internals;
* batching.

## Unit tests

Mock session provider:

* проверяет порядок вызовов:
  `start -> next_logits -> commit -> next_logits -> commit -> end`;
* если `commit` не вызван, следующий logits не меняется.

## Integration tests

На fake sidecar проверить JSONL protocol.

## DoD

* [x] Provider поддерживает session mode.
* [x] `generate` использует session, если provider его поддерживает.
* [x] Stateless fallback сохранен.
* [x] Metrics пишет `provider-session?`.

---
