# 028. Оптимизировать exact full-vocab soft sampler или честно зафиксировать infeasible

Status: todo

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

