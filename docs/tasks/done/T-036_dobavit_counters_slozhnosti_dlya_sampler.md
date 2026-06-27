# T-036. Добавить counters сложности для sampler

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Семплер должен считать операции для анализа сложности статьи: expanded nodes, created edges, agenda push/pop, max frontier, provider calls, grammar checks, accepted candidates.

### В скоупе

- `sampling/sampler-stats.rkt`.
- Stats attached to candidate trace and run summary.

### Не в скоупе

- CPU profiling.
- Flamegraphs.

### Публичные интерфейсы

```racket
(struct sampler-stats
  ([expanded-nodes : Natural]
   [created-edges : Natural]
   [agenda-pushes : Natural]
   [agenda-pops : Natural]
   [max-frontier : Natural]
   [provider-calls : Natural]
   [grammar-checks : Natural]
   [yielded-candidates : Natural])
  #:transparent)
```

### Unit tests

```racket
(define-values (ys stats) (run-small-stream ...))
(check-true (> (sampler-stats-expanded-nodes stats) 0))
(check-true (>= (sampler-stats-agenda-pushes stats) (sampler-stats-agenda-pops stats)))
```

### Integration tests

- Complexity benchmark writes CSV with stats.

### Definition of Done (DoD)

- Stats present in trace.
- Complexity docs use same symbols as stats.
