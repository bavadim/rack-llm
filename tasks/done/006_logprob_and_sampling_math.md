# Исправить LM logprob scoring и sampling math

Status: done

## SMART goal

За 2 рабочих дня заменить суммирование raw logits на корректный log-softmax score и подготовить функции для stochastic sampling.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

- Реализовать `log-softmax-vector`.
- Реализовать `token-logprob(provider, prompt, prefix, token-id)`.
- Исправить `sequence-score`: сумма log-probability, а не raw logits.
- Добавить temperature handling.
- Добавить Gumbel-Max helper для sampling из adjusted logits.
- Добавить deterministic seed support для sampling.

## Out of scope

- Не реализовывать весь `generate`.
- Не реализовывать top-p/top-k sampling, если это раздувает задачу. Достаточно temperature + categorical/Gumbel.

## Public interfaces / touched interfaces

```racket
(log-softmax logits) -> vector
(sequence-logprob provider prompt text) -> real
(sample-id adjusted-logits rng temperature) -> id
```

## Scientific / design notes

Итоговый score кандидата должен быть:

```text
total = lm_logprob + beta * guide_score
```

Без корректного `lm_logprob` нельзя сравнивать candidates и keep-best, даже если очень хочется притвориться.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- На logits `[0 0]` log-softmax дает `[-log 2, -log 2]`.
- На фиксированном mock provider `sequence-logprob` совпадает с ручным расчетом.
- Sampling с одинаковым seed воспроизводим.

## Integration tests

- `generate` или временный smoke-test использует `sequence-logprob`.
- `total_score` меняется ожидаемо при изменении beta.

## Definition of Done

- [x] Raw logits больше не суммируются как score последовательности.
- [x] Есть unit-тесты log-softmax.
- [x] Есть seed-controlled sampling helper.
- [x] Документировано различие logits/logprobs.

## Result

Добавлены `log-softmax`, `sequence-logprob`, `sample-id`; finite candidate
scoring и open-text LM score теперь используют log-probabilities вместо raw
logits. Добавлена документация `docs/sampling.md`.
