# Задача 003. Запретить `check/parse-guide` внутри token loop

Исходный номер в `tasks.md`: 002.


## SMART goal

За 2 рабочих дня убрать вызовы `check`, `parse-guide`, `finite-candidates` из внутреннего цикла выбора следующего токена. Генерация должна использовать только prefix-runtime `init/step/dead?/done?/score/potential`.

## Scope

В задаче:

* добавить счетчик `check-calls-in-sampling`;
* заменить `guide-step`, который сейчас пересоздает `runtime-state` по полной строке;
* сделать так, чтобы `generate` при sampling не вызывал `check` до финализации;
* если guide-kind не поддерживает prefix-runtime, возвращать статус:

  ```racket
  'unsupported-guide-for-sampling
  ```

  или бросать понятную ошибку в dev-режиме.

## Out of scope

Не входит:

* реализация всех prefix-state для всех guide-kind;
* оптимизация regex;
* изменение public API.

## Зачем

Сейчас логика вида:

```racket
check guide (prefix + token)
```

на каждый токен превращает генерацию в:

[
O(T \cdot V \cdot C_{\text{check}}(T))
]

Нужно:

[
O(T \cdot V \cdot C_{\text{step}})
]

## Public/internal interfaces

Ввести внутренний протокол:

```racket
guide-init-runtime : Guide -> RuntimeState
guide-step-runtime : RuntimeState TokenId TokenString -> RuntimeState
runtime-dead?      : RuntimeState -> Boolean
runtime-done?      : RuntimeState -> Boolean
runtime-score      : RuntimeState -> Real
runtime-potential  : RuntimeState -> Real
runtime-value      : RuntimeState -> Any
runtime-trace      : RuntimeState -> Trace
```

## Unit tests

Тест “префикс не равен dead”:

```racket
(define g (seq "A" (select "B" "C")))
(define s0 (guide-init-runtime g))
(define s1 (guide-step-runtime s0 token-id-A "A"))

(check-false (runtime-dead? s1))
(check-false (runtime-done? s1))
```

Тест “мертвый токен”:

```racket
(define s-bad (guide-step-runtime s0 token-id-X "X"))
(check-true (runtime-dead? s-bad))
```

## Integration tests

Запустить `generate` на mock provider и проверить метрики:

```racket
(hash-ref metrics 'check-calls-in-sampling) => 0
(hash-ref metrics 'parse-guide-calls-in-sampling) => 0
```

## DoD

* [x] Во время `generate` не вызывается `check`.
* [x] Во время `generate` не вызывается `parse-guide`.
* [x] Prefix `"A"` для `(seq "A" "B")` получает статус `live`, а не `dead`.
* [x] Неподдержанный guide-kind явно помечается как unsupported, а не silently падает в slow path.

---
