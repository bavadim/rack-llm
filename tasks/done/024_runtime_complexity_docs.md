# Задача 024. Обновить документацию runtime complexity

Исходный номер в `tasks.md`: 024.


## SMART goal

За 1 рабочий день обновить docs так, чтобы было ясно: какие режимы exact, какие approximate, где гарантии, где скорость, где память.

## Scope

Документировать:

* hard exact:
  [
  O(TV)
  ]
  если full-vocab нужен;
* allowed-only:
  [
  O(TA)
  ]
  где (A) — число допустимых token ids;
* soft top-k+watch:
  [
  O(T(K+W))
  ]
* почему exact uniqueness не гарантируется без памяти;
* что `check` не используется в token loop.

## Out of scope

Не входит:

* статья;
* экспериментальный протокол;
* tutorial.

## DoD

* [x] `docs/runtime.md` обновлен.
* [x] `docs/sampling.md` обновлен.
* [x] README кратко описывает candidate policies.
* [x] Документация явно предупреждает про `top-k+watch` approximation.

---
