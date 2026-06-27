# T-065. Реализовать aggregation baselines: majority и equal weights

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Реализовать простые агрегации слабых правил как baselines к Dawid–Skene: majority vote и equal-weight score.

### В скоупе

- Majority per constraint.
- Equal weights per constraint.
- Threshold config.

### Не в скоупе

- Manual tuned weights.
- Supervised logistic regression.

### Публичные интерфейсы

```racket
(: majority-posterior-like (-> (Listof rule-observation) Flonum))
(: equal-weight-score (-> (Listof rule-observation) Flonum))
```

### Implementation notes

Возвращать score in `[0,1]`, чтобы можно было сравнивать Brier/ECE, но честно в docs написать, что это не calibrated posterior.

### Unit tests

```racket
(check-= (majority-posterior-like '(accept accept reject)) 1.0 1e-9)
(check-= (majority-posterior-like '(accept reject abstain)) 0.5 1e-9)
```

### Integration tests

- Weak-IFBench runner can switch aggregation mode.

### Definition of Done (DoD)

- Majority/equal baselines share same acceptance interface.
- Tables include DS vs majority/equal.

---
