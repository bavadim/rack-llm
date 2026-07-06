# Ввести практичную семантику found/not-found

Status: done

## SMART goal

За 1 рабочий день заменить булево `ok?` в результате генерации на статусы, пригодные для hard и soft режимов.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

- Расширить `generation-result` полями `status`, `reason`, `hard-ok?`, `low-score?`.
- Поддержать статусы: `found`, `not-found-hard`, `not-found-budget`, `not-found-low-score`, `error-approx-provider`, `internal-invalid`.
- Описать маппинг статусов в документации `docs/status.md`.
- Сохранить backwards-compatible helper `(generation-result-ok? r)`, если нужно, но он должен быть derived: true только для `status='found`.

## Out of scope

- Не добавлять external verifier.
- Не добавлять IFBench `FOUND_OK/FOUND_WRONG`, это внешний слой.
- Не добавлять threshold в DSL.

## Public interfaces / touched interfaces

```racket
(struct generation-result
  (status reason text value lm-logprob guide-score total-score hard-ok? low-score? steps attempts generated-tokens latency-ms trace metrics)
  #:transparent)
```

## Scientific / design notes

В hard-only режиме “найдено ошибочное” относительно DSL должно быть невозможно: `found` означает, что собственный `check` проходит. В soft-only режиме `not-found` появляется только из бюджета или return-policy, а не из самой открытой генерации.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Создать результаты каждого статуса и проверить predicates.
- `found?`, `not-found?`, `hard-failure?` возвращают ожидаемые значения.
- `generation-result-ok?` true только для `found`.

## Integration tests

- `generate` на заведомо невозможном hard guide возвращает `not-found-hard` или `not-found-budget`, а не `ok? #f` без причины.
- `generate` на `text` без threshold возвращает `found`.

## Definition of Done

- [x] Статусы реализованы.
- [x] Документация `docs/status.md` есть.
- [x] Старое поле `ok?` больше не является единственным способом понять результат.
- [x] Все причины отказа отражаются в `reason`.

## Result

`generation-result` расширен статусами, reason и техническими полями.
Добавлены `found?`, `not-found?`, `hard-failure?`; `generation-result-ok?`
теперь derived helper для `status='found`. Добавлена документация
`docs/status.md` и интеграционные тесты для hard failure и open text.
