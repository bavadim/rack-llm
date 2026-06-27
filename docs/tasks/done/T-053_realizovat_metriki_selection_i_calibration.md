# T-053. Реализовать метрики selection и calibration

**Category:** Resampling, tracing и метрики  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить метрики главного эксперимента: `GoldSuccess@B`, `Oracle@B`, `SelectionEfficiency@B`, `ConstraintSuccess@B`, `Brier`, `ECE`, `AUROC`, `duplicate-rate`, `avg-candidates`.

### В скоупе

- `experiments/metrics.rkt`.
- Метрики по prompt-level и constraint-level.
- CSV/JSON output.

### Не в скоупе

- Статистические significance tests.
- Plotting.
- Leaderboard integration.

### Публичные интерфейсы

```racket
(struct eval-record
  ([task-id : String]
   [budget : Natural]
   [selected-rank : (Option Natural)]
   [gold-success? : Boolean]
   [oracle-success? : Boolean]
   [constraint-gold : (HashTable Symbol Boolean)]
   [eta : Flonum]
   [accepted? : Boolean]
   [duplicate-rate : Flonum]
   [latency-ms : Nonnegative-Flonum])
  #:transparent)

(: gold-success-at-b (-> (Listof eval-record) Flonum))
(: oracle-at-b (-> (Listof eval-record) Flonum))
(: selection-efficiency-at-b (-> (Listof eval-record) Flonum))
(: brier-score (-> (Listof eval-record) Flonum))
(: ece-score (-> (Listof eval-record) Natural Flonum))
```

### Implementation notes

`SelectionEfficiency@B = GoldSuccess@B / Oracle@B`. Если `Oracle@B = 0`, вернуть `nan` или structured missing, не 0. Деление на ноль — древний способ испортить график.

### Unit tests

```racket
(check-= (gold-success-at-b records) 0.5 1e-9)
(check-= (oracle-at-b records) 0.75 1e-9)
(check-= (selection-efficiency-at-b records) (/ 0.5 0.75) 1e-9)
(check-= (brier-score perfect-records) 0.0 1e-9)
```

### Integration tests

- Metrics reader consumes trace + gold file and outputs CSV.

### Definition of Done (DoD)

- All metrics unit-tested.
- Output format stable.
- Metrics definitions documented in `docs/weak-ifbench.md`.

---
