# 028. Оптимизировать exact full-vocab soft sampler или честно зафиксировать infeasible

Status: todo

## Current status 2026-07-09

Still current as an umbrella task for performance evidence and benchmark
artifact decisions. `032_repair_exact_full_vocab_soft_sampler.md` is closed:
exact full-vocabulary soft decoding remains atomic, bounded by `#:max-tokens`,
and covered by real Qwen e2e tests.

Do not regenerate paper artifacts until this task records whether the current
bounded exact mode is sufficient for paper claims or whether exact soft claims
must be invalidated for the current runtime.

## Problem

`ours_soft_*` больше не должен использовать `top-k-approx` как paper-grade
режим. Full-vocab режим должен доказывать, что каждый generated token был
выбран после полного прохода по словарю. Основная стоимость остается в
candidate evaluation для open text watchers, поэтому прикладные тесты должны
быть bounded через `#:max-tokens` и проверять реальное время на Qwen.

## DoD

- Есть benchmark/trace, показывающий стоимость одного full-vocab sampling pass.
- Реализован один из вариантов:
  - bounded exact full-vocab задачи укладываются в проверяемый latency budget
    на Qwen3.5-4B; или
  - метод явно объявлен infeasible для текущего runtime и exact soft claims
    invalidated.
- Нельзя возвращаться к top-k как main result.
- `racket_ours_soft_batch.rkt` main mode остается `exact-full-vocab`.
