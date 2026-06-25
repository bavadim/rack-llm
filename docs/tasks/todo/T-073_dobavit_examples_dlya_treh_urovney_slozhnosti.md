# T-073. Добавить examples для трех уровней сложности

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить 3 runnable examples: simple JSON, rule resampling, Weak-IFBench-style mini task.

### В скоупе

- `examples/01-json-grammar.rkt`.
- `examples/02-rule-resampling.rkt`.
- `examples/03-weak-constraint-mini.rkt`.
- Все на mock-provider.

### Не в скоупе

- Реальная LLM.
- Большие benchmarks.

### Публичные интерфейсы

Examples должны запускаться:

```bash
racket examples/01-json-grammar.rkt
racket examples/02-rule-resampling.rkt
racket examples/03-weak-constraint-mini.rkt
```

### Implementation notes

Каждый пример до 80 строк. Если пример занимает 300 строк, это уже не пример, а признание API-провала.

### Unit tests

Examples smoke:

```bash
make test-examples
```

### Integration tests

CI runs examples.

### Definition of Done (DoD)

- Все examples запускаются.
- Outputs deterministic.
- Examples упомянуты в README.

---
