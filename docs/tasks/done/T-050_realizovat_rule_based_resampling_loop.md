# T-050. Реализовать rule-based resampling loop

**Category:** Resampling, tracing и метрики  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить функцию, которая берет кандидатов из Gumbel-stream и возвращает первый кандидат, прошедший `AcceptanceModel`, либо `FAIL` после исчерпания бюджета.

### В скоупе

- `resample-until-accepted`.
- Budget by candidates, nodes, time.
- Return selected candidate or fail report.
- Full trace of rejected candidates.

### Не в скоупе

- Repair prompt.
- Adaptive budget.
- Parallel generation.

### Публичные интерфейсы

```racket
(struct resampling-config
  ([candidate-budget : Natural]
   [node-budget : Natural]
   [time-budget-ms : Natural]
   [on-fail : (U 'return-fail 'return-best-by-score)])
  #:transparent)

(struct resampling-result
  ([status : (U 'accepted 'failed)]
   [selected : (Option candidate)]
   [selected-rank : (Option Natural)]
   [checked : Natural]
   [trace : (Listof candidate-trace)])
  #:transparent)

(: resample-until-accepted
   (-> resampling-config
       (Sequenceof candidate)
       (-> candidate acceptance-decision)
       resampling-result))
```

### Implementation notes

Важное разделение:

- Reject без изменения prompt: берем следующий candidate из того же Gumbel-stream.
- Repair prompt: это новая задача T-051, потому что распределение уже другое.

### Unit tests

```racket
(define candidates (list->stream (list bad1 bad2 good)))
(define result (resample-until-accepted cfg candidates accept-if-good))
(check-equal? (resampling-result-status result) 'accepted)
(check-equal? (resampling-result-selected-rank result) 3)
(check-equal? (resampling-result-checked result) 3)
```

Fail test:

```racket
(check-equal? (resampling-result-status (resample-until-accepted cfg all-bad reject-all)) 'failed)
```

### Integration tests

- With Gumbel-stream fixture, first candidate rejected by rule, second accepted.
- Trace contains both candidates and decisions.

### Definition of Done (DoD)

- Resampling loop works with any candidate stream.
- No hidden call to LLM outside stream.
- Budget behavior deterministic.

---
