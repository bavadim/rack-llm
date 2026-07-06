# Добавить return policy для soft abstention

Status: done

## SMART goal

За 2 рабочих дня добавить runtime-политику возврата результата, чтобы библиотека могла практично возвращать `not-found-low-score` без добавления `accept score` в DSL.

## Dependencies

Зависит от `015_generate_stream_and_best_of.md`.

## Scope

- Реализовать политики:
  - `'always`
  - `'hard-only`
  - `(min-guide-score τ)`
  - `(min-total-score τ)`
- Policy применяется после генерации кандидатов/samples.
- Если лучший кандидат ниже порога, вернуть `not-found-low-score`.
- Hard failure/budget имеют приоритет над low-score.
- Policy не должна быть частью DSL-выражения.

## Out of scope

- Не реализовывать risk-target/dev-set threshold.
- Не добавлять IFBench-specific SafeSolve.
- Не добавлять supervised calibration.

## Public interfaces / touched interfaces

```racket
(generate provider prompt guide
          #:return-policy 'always)
(generate provider prompt guide
          #:return-policy (min-guide-score 3.0))
```

## Scientific / design notes

В soft-only мире строка почти всегда найдется, но может быть бесполезной по внутреннему score. `return-policy` — практичный способ сказать “лучше не вернуть ничего, чем вернуть низкоскорный мусор”, не загрязняя DSL.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `text` без policy возвращает `found` даже при score 0.
- `text` с `(min-guide-score 1)` и score 0 возвращает `not-found-low-score`.
- Hard impossible возвращает `not-found-hard`, не low-score.
- Best-of-N policy проверяет лучший candidate.

## Integration tests

- `generate` с soft threshold корректно abstains.
- Status reason содержит threshold и observed score.

## Definition of Done

- [x] Return-policy реализована.
- [x] DSL не содержит `accept-score`.
- [x] Документировано различие soft low-score и hard not-found.

## Result

`generate` получил `#:return-policy` с режимами `'always`, `'hard-only`,
`(min-guide-score n)`, `(min-total-score n)`. Low-score abstention применяется
только к `found` результатам; hard/budget failures сохраняют исходный статус.
