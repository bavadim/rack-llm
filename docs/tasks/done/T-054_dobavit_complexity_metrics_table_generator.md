# T-054. Добавить complexity metrics table generator

**Category:** Resampling, tracing и метрики  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

На основе sampler stats и trace генерировать таблицу сложности для статьи: `expanded_nodes`, `created_edges`, `max_frontier`, `provider_calls`, `grammar_checks`, `queue_time_ms`, `provider_time_ms`, `rules_time_ms`.

### В скоупе

- Aggregation by run/method/budget.
- CSV output.
- Mean/std.

### Не в скоупе

- Plotting.
- GPU profiler.

### Публичные интерфейсы

CLI:

```bash
racket experiments/analyze-complexity.rkt traces/*.jsonl --out complexity.csv
```

### Unit tests

```racket
(check-equal? (aggregate-complexity sample-traces 'expanded_nodes) expected)
```

### Integration tests

- Synthetic benchmark produces complexity.csv.

### Definition of Done (DoD)

- Complexity table can be produced from trace without rerunning experiments.
- Column names match `docs/complexity.md`.
