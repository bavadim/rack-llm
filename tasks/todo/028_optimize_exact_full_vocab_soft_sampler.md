# 028. Оптимизировать exact full-vocab soft sampler или честно зафиксировать infeasible

Status: todo

## Current status 2026-07-08

Still current. The library now has `private/sampling.rkt`, but exact
full-vocabulary soft decoding still checks `#:deadline-ms` only around the
generation step, not inside the candidate loop. A synthetic 20k-vocab open-text
run with `#:deadline-ms 1` returned `error-budget` only after finishing one
full candidate pass and generating one token.

This task should be implemented through `032_repair_exact_full_vocab_soft_sampler.md`.
Do not regenerate paper artifacts until that repair either makes exact mode
practical or marks it fail-closed infeasible.

## Problem

`ours_soft_*` больше не должен использовать `top-k-approx` как paper-grade
режим. После переключения на `exact-full-vocab` маленький smoke
`1 row x 1 sample x 3 tokens` завершается управляемым `error-budget`, но полный
vocabulary pass слишком медленный: основная стоимость в `watcher-score` для
каждого token candidate.

## DoD

- Есть benchmark/trace, показывающий стоимость одного full-vocab sampling pass.
- Реализован один из вариантов:
  - exact full-vocab pass укладывается в заданный deadline на Qwen3.5-4B; или
  - метод явно объявлен infeasible для текущего runtime с error-budget rows.
- Нельзя возвращаться к top-k как main result.
- `racket_ours_soft_batch.rkt` main mode остается `exact-full-vocab`.
