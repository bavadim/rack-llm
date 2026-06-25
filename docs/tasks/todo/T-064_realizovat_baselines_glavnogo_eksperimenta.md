# T-064. Реализовать baselines главного эксперимента

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 8 рабочих дней

### SMART goal

Добавить baseline methods для честного сравнения: pass@1, independent sampling, independent+majority, independent+DS, Gumbel+majority, Gumbel+DS, exact verifier oracle.

### В скоупе

- Common method interface.
- Candidate generation budget `B`.
- Same provider/model/prompt across methods.
- Same weak rules across methods.

### Не в скоупе

- Сравнение с внешними leaderboard models.
- Beam search baseline, если нет времени.
- RL/fine-tuned baselines.

### Публичные интерфейсы

```racket
(define-type MethodId
  (U 'pass1
     'independent-sampling
     'independent-majority
     'independent-ds
     'gumbel-majority
     'gumbel-ds
     'oracle-verifier))

(struct method-result
  ([method : MethodId]
   [task-id : String]
   [budget : Natural]
   [selected : (Option candidate)]
   [trace : (Listof candidate-trace)])
  #:transparent)

(: run-method (-> MethodId experiment-context ifbench-task Natural method-result))
```

### Implementation notes

`oracle-verifier` использует gold verifier для выбора кандидата и является upper bound, не реальным методом. В таблицах пометить как `oracle upper bound`.

### Unit tests

```racket
(check-equal? (method-result-method (run-method 'pass1 ctx task 1)) 'pass1)
(check-exn exn:fail? (lambda () (run-method 'pass1 ctx task 8))) ; pass1 ignores/forbids B>1 unless explicit
```

### Integration tests

- Fixture run outputs one row per method per budget.
- Oracle@B >= GoldSuccess@B for all non-oracle methods.

### Definition of Done (DoD)

- All required baselines run with same CLI.
- Metrics grouped by method and budget.
- Oracle clearly marked as upper bound.

---
