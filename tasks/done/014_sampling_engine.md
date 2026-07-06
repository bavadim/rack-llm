# Реализовать потоковый stochastic sampling engine

Status: done

## SMART goal

За 4 рабочих дня заменить greedy выбор токена на stochastic rule-guided sampling с beta, lambda, temperature и seed.

## Dependencies

Зависит от `006`, `007`, `008`, `009`, `013`.

## Scope

- Использовать prefix runtime.
- На каждом шаге вычислять adjusted logits:

```text
adjusted = lm_logprob + beta * (delta_score + lambda * delta_potential)
```

- Hard-dead токены маскировать `-inf`.
- Поддержать `#:beta`, `#:lambda`, `#:temperature`, `#:seed`, `#:max-tokens`, `#:deadline-ms`.
- Вернуть `generation-result` со статусом и метриками.
- Поддержать deterministic sampling при seed.

## Out of scope

- Не реализовывать exact sequence-level Gumbel top-k.
- Не гарантировать уникальность.
- Не делать IFBench runner.

## Public interfaces / touched interfaces

```racket
(generate provider prompt guide
          #:beta 1.0
          #:lambda 0.5
          #:temperature 0.7
          #:seed 42
          #:max-tokens 128)
```

## Scientific / design notes

Библиотека должна семплировать из локальной аппроксимации:

```text
q_t(v) ∝ p(v|prefix) * exp(beta * (Δscore + lambda * Δpotential))
```

Это практичный алгоритм с константной search memory. Уникальность и строгая сортировка не являются core-целями.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- При beta=0 результат совпадает со stochastic sampling по LLM logits на mock provider.
- При большом beta ranked branch выбирается чаще на controlled mock.
- Hard-dead токен никогда не выбирается.
- Seed воспроизводим.

## Integration tests

- `generate` на closed guide возвращает `found` или `not-found-*` с причиной.
- `generate` на text with rank меняет distribution относительно beta=0.
- Metrics содержат steps/generated-tokens/latency.

## Definition of Done

- [x] Greedy-only логика удалена или стала частным режимом.
- [x] Sampling работает через adjusted logits.
- [x] Все статусы заполняются.
- [x] Нет вызова `check(prefix)` как основного механизма pruning.

## Result

Open decoding now samples token ids with seed-controlled Gumbel-Max over
adjusted logits. `generate` supports `#:lambda`, `#:temperature`, `#:seed`,
`#:deadline-ms`; hard-dead tokens are masked to `-inf.0`; result metrics include
steps, generated tokens, and latency.
