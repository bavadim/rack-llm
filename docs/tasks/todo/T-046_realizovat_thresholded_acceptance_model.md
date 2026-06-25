# T-046. Реализовать thresholded acceptance model

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Собрать hard rules и DS posteriors в единый `AcceptanceModel`, который принимает кандидата, если hard rules passed and all/aggregated weak constraints pass thresholds.

### В скоупе

- Candidate-level acceptance.
- Per-constraint acceptance.
- Threshold config.
- Diagnostics: why rejected.

### Не в скоупе

- Prompt repair generation.
- Learning threshold automatically beyond dev-set helper.

### Публичные интерфейсы

```racket
(struct acceptance-config
  ([mode : (U 'all-constraints 'weighted-sum 'min-posterior)]
   [default-threshold : Flonum]
   [constraint-thresholds : (HashTable Symbol Flonum)]
   [weights : (HashTable Symbol Flonum)])
  #:transparent)

(struct acceptance-decision
  ([accepted? : Boolean]
   [hard-passed? : Boolean]
   [score : Flonum]
   [constraint-posteriors : (HashTable Symbol Flonum)]
   [diagnostics : (Listof String)])
  #:transparent)

(: accept-candidate
   (-> acceptance-config acceptance-report per-constraint-ds-model acceptance-decision))
```

### Implementation notes

Default mode для Weak-IFBench:

```text
all constraints eta_c >= tau_c
```

Это жестко, но понятно. Weighted sum можно оставить для ablation.

### Unit tests

```racket
(define d (accept-candidate cfg hard-ok-report ds-model obs))
(check-true (boolean? (acceptance-decision-accepted? d)))
(check-true (hash? (acceptance-decision-constraint-posteriors d)))
```

Rejection reason:

```racket
(check-true (member "constraint word-count below threshold" diagnostics))
```

### Integration tests

- Candidate rejected when one constraint below threshold.
- Candidate accepted when all constraints above threshold.

### Definition of Done (DoD)

- Acceptance deterministic and traceable.
- Thresholds configurable.
- Diagnostics human-readable.

---
