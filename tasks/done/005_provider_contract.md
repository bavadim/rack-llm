# Уточнить контракт LLM provider

Status: done

## SMART goal

За 2 рабочих дня сделать provider-контракт, достаточный для hard и soft decoding без привязки к экспериментам.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

- Определить provider fields: `vocab`, `next-logits`, `mode`, `metadata`.
- Поддержать режимы: `exact-full-vocab`, `top-k-approx`, `mock`.
- `next-logits` должен возвращать vector logits длины vocab для exact/mock режима.
- Для top-k режима разрешить sparse результат, но hard decoder должен уметь вернуть `error-approx-provider`, если нет жизнеспособного токена.
- Оставить `make-mock-provider` для тестов.

## Out of scope

- Не реализовывать реальный llama.cpp provider в этой задаче.
- Не реализовывать OpenAI API adapter.
- Не делать HTTP-клиент.

## Public interfaces / touched interfaces

```racket
(make-provider #:vocab vocab #:next-logits f #:mode 'exact-full-vocab #:metadata meta)
(provider-vocab p)
(provider-next-logits p)
(provider-mode p)
```

## Scientific / design notes

Для строгого hard guidance нужны полные logits или хотя бы гарантированная поддержка допустимых токенов. Top-K режим является приближением и не должен молча маскироваться под точный.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `make-provider` отклоняет vocab не из строк.
- `exact-full-vocab` требует vector нужной длины.
- `mock` deterministic по prefix.
- `top-k-approx` помечается mode field.

## Integration tests

- Простая генерация через mock provider работает.
- Hard guide с exact provider не возвращает provider error.
- С top-k provider и пустым допустимым набором возвращается понятный provider статус.

## Definition of Done

- [x] Provider API описан в `docs/provider.md`.
- [x] Старый provider код адаптирован.
- [x] Mock provider используется во всех unit-тестах.
- [x] Нет внешних сетевых зависимостей.

## Result

`provider` получил поля `mode` и `metadata`; `make-provider` поддерживает
`exact-full-vocab`, `top-k-approx`, `mock`. Добавлена нормализация sparse
top-k logits и статус `error-approx-provider`, когда approximate provider не
возвращает допустимый токен. Контракт описан в `docs/provider.md`.
