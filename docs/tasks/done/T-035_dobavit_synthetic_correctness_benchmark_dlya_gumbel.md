# T-035. Добавить synthetic correctness benchmark для Gumbel

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Создать synthetic benchmark, где пространство строк полностью перечисляется, чтобы сравнить Gumbel-stream с явным Gumbel-Top-k и измерить TV/KL для repeated runs.

### В скоупе

- Маленькие грамматики: enum, brackets, JSON-like.
- Mock autoregressive distributions.
- Exact enumeration.
- Metrics: duplicate rate, TV, KL, order agreement.

### Не в скоупе

- Реальные LLM.
- Weak heuristics.
- IFBench.

### Публичные интерфейсы

CLI:

```bash
racket experiments/synthetic/gumbel-correctness.rkt --seed 42 --runs 10000
```

Functions:

```racket
(: enumerate-language (-> provider matcher Natural (Listof candidate)))
(: total-variation (-> Distribution Distribution Flonum))
(: kl-divergence (-> Distribution Distribution Flonum))
```

### Implementation notes

Для маленьких деревьев можно brute-force. Это нормально: benchmark проверяет математику, а не скорость.

### Unit tests

```racket
(check-= (total-variation p p) 0.0 1e-9)
(check-= (kl-divergence p p) 0.0 1e-9)
```

### Integration tests

- `make test-synthetic-small` запускает 100 runs быстро.
- Full benchmark optional.

### Definition of Done (DoD)

- Есть таблица synthetic metrics.
- Duplicate rate = 0.
- Расхождение с explicit enumeration укладывается в заранее заданный tolerance.

---
