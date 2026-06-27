# T-047. Добавить correlation diagnostics для правил

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить анализ согласия и корреляции правил, чтобы предупреждать пользователя, если несколько эвристик почти дублируют друг друга и нарушают DS independence assumption.

### В скоупе

- Pairwise agreement matrix.
- Conflict matrix.
- High-correlation warnings.
- Report in metrics.

### Не в скоупе

- Correlation-aware label model.
- Automatic rule pruning.

### Публичные интерфейсы

```racket
(struct rule-correlation-report
  ([agreement : (HashTable (Pairof Symbol Symbol) Flonum)]
   [conflict : (HashTable (Pairof Symbol Symbol) Flonum)]
   [warnings : (Listof String)])
  #:transparent)

(: analyze-rule-correlations
   (-> (Listof (Listof rule-observation)) rule-correlation-report))
```

### Unit tests

```racket
(define report (analyze-rule-correlations duplicated-rule-observations))
(check-true (not (null? (rule-correlation-report-warnings report))))
```

### Integration tests

- Weak-IFBench metrics include number of high-correlation pairs.

### Definition of Done (DoD)

- Correlation warnings appear in trace/metrics.
- Docs state DS independence limitation.
