# T-045. Реализовать per-constraint Dawid–Skene

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 6 рабочих дней

### SMART goal

Добавить поддержку DS по группам ограничений: для каждого constraint type или конкретного constraint считается отдельный posterior `eta_c(y)`.

### В скоупе

- `constraint-id` in rule observations.
- Fit DS per group.
- Predict vector of posteriors.
- Aggregate candidate acceptance over constraints.

### Не в скоупе

- Hierarchical Bayesian model.
- Correlation-aware DS.

### Публичные интерфейсы

```racket
(struct constraint-observation
  ([constraint-id : Symbol]
   [rule-observation : rule-observation])
  #:transparent)

(struct per-constraint-ds-model
  ([models : (HashTable Symbol ds-model)]
   [fallback-model : (Option ds-model)])
  #:transparent)

(: fit-per-constraint-ds
   (-> ds-config (Listof (Listof constraint-observation)) per-constraint-ds-model))

(: constraint-posteriors
   (-> per-constraint-ds-model (Listof constraint-observation)
       (HashTable Symbol Flonum)))
```

### Implementation notes

Если constraint group слишком мала, использовать fallback model по constraint type. В trace писать `fallback-used?`.

### Unit tests

```racket
(define model (fit-per-constraint-ds cfg observations))
(define ps (constraint-posteriors model obs-for-candidate))
(check-true (hash-has-key? ps 'word-count))
(check-true (<= 0.0 (hash-ref ps 'word-count) 1.0))
```

### Integration tests

- Weak-IFBench fixture with two constraint types: word count and phrase presence.
- Acceptance requires both posteriors above threshold.

### Definition of Done (DoD)

- DS can be trained per constraint group.
- Fallback behavior documented.
- Trace includes constraint posteriors.

---
