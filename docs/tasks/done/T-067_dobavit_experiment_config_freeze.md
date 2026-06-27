# T-067. Добавить experiment config freeze

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

Каждый эксперимент должен сохранять immutable config file, чтобы результаты можно было воспроизвести: provider, model, prompt template, grammar, weak rules, budgets, seeds, split ids.

### В скоупе

- `experiment-config.json`.
- Hash of config.
- Config included in run metadata.

### Не в скоупе

- Full environment capture with Docker.
- Model file upload.

### Публичные интерфейсы

```racket
(: write-experiment-config (-> experiment-config Path-String Void))
(: experiment-config-hash (-> experiment-config String))
```

### Unit tests

```racket
(check-equal? (experiment-config-hash cfg) (experiment-config-hash cfg))
(check-not-equal? (experiment-config-hash cfg1) (experiment-config-hash cfg2))
```

### Integration tests

- Every run output dir contains config and hash.

### Definition of Done (DoD)

- Run cannot start without writing config.
- Config hash appears in metrics rows.
