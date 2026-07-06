# Задача 012. Ввести строгую семантику статусов `found/not-found`

Исходный номер в `tasks.md`: 017.


## SMART goal

За 1 рабочий день унифицировать статусы результата и причины отказа, чтобы hard/soft/hybrid режимы возвращали практичные и различимые outcomes.

## Scope

В задаче:

* зафиксировать статусы:

  ```racket
  'found
  'not-found-hard
  'not-found-budget
  'not-found-low-score
  'error-budget
  'error-approx-provider
  'internal-invalid
  'unsupported-guide-for-sampling
  ```
* добавить predicates:

  ```racket
  found?
  not-found?
  hard-failure?
  low-score?
  provider-error?
  ```
* hard-found должен гарантировать `check.ok?`.

## Out of scope

Не входит:

* IFBench `FOUND_OK/FOUND_WRONG`;
* external verifier;
* experiment runners.

## Unit tests

* hard impossible guide → `not-found-hard`;
* max-token exhaustion → `not-found-budget`;
* soft low threshold → `not-found-low-score`;
* generated hard-invalid → `internal-invalid`.

## DoD

* [x] Все статусы документированы.
* [x] Все статусы покрыты unit tests.
* [x] `found` для hard guide всегда проходит `check`.
* [x] Soft mode без return-policy не возвращает `not-found-low-score`.

---
