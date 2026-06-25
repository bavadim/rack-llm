# T-043. Реализовать Dawid–Skene binary latent model

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 8 рабочих дней

### SMART goal

Реализовать Dawid–Skene model для бинарного скрытого качества кандидата `z in {0,1}` и наблюдений правил `accept/reject/abstain`. EM должен оценивать матрицы ошибок каждого правила и возвращать posterior `eta(y)`.

### В скоупе

- `rules/dawid-skene.rkt`.
- Outcomes: `accept`, `reject`, `abstain`.
- EM with smoothing.
- Fit без gold labels.
- Predict posterior.
- Save/load model JSON.

### Не в скоупе

- Multi-class DS.
- Correlation-aware label model.
- End-to-end IFBench runner.

### Публичные интерфейсы

```racket
(define-type DSClass (U 0 1))
(define-type DSOutcome RuleDecision)

(struct ds-config
  ([max-iter : Natural]
   [tol : Flonum]
   [smoothing : Flonum]
   [prior-good : Flonum])
  #:transparent)

(struct ds-model
  ([rule-ids : (Listof Symbol)]
   [prior-good : Flonum]
   [confusions : (HashTable Symbol Any)]
   [iterations : Natural]
   [converged? : Boolean])
  #:transparent)

(: fit-dawid-skene
   (-> ds-config (Listof (Listof rule-observation)) ds-model))

(: ds-posterior
   (-> ds-model (Listof rule-observation) Flonum))

(: ds-model->json (-> ds-model JSExpr))
(: json->ds-model (-> JSExpr ds-model))
```

### Implementation notes

Матрица правила:

```text
Pi_k[z, outcome] = P(h_k = outcome | z)
outcome in accept/reject/abstain
```

Использовать log-space для posterior, чтобы не перемножать мелкие числа до нуля. Сглаживание обязательно.

Проблема ориентации классов: DS может поменять местами good/bad. Это не баг, а неприятная математика. Для фиксации ориентации см. T-044.

### Unit tests

Synthetic recovery:

```racket
(define synthetic (make-ds-synthetic-data
                   #:n 1000
                   #:rules '((r1 0.95 0.05 0.0) (r2 0.75 0.20 0.05))))
(define m (fit-dawid-skene default-ds-config synthetic-observations))
(check-true (< (abs (- (estimated-accuracy m 'r1) 0.95)) 0.05))
```

Posterior bounds:

```racket
(check-true (<= 0.0 (ds-posterior m obs) 1.0))
```

Serialization:

```racket
(check-equal? (json->ds-model (ds-model->json m)) m)
```

### Integration tests

- Compare DS vs majority on synthetic noisy rules. DS should have higher AUROC when rules have unequal accuracy.

### Definition of Done (DoD)

- EM converges or reports non-convergence.
- `abstain` is modeled explicitly.
- Synthetic tests pass with tolerance.
- JSON serialization works.

---
