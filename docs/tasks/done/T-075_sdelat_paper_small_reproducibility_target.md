# T-075. Сделать `paper-small` reproducibility target

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить команду `make paper-small`, которая запускает маленький воспроизводимый pipeline: synthetic test + Weak-IFBench fixture + metrics tables.

### В скоупе

- Synthetic small.
- Weak-IFBench fixture.
- Metrics output.
- Trace output.

### Не в скоупе

- Full benchmark.
- Реальная LLM.

### Публичные интерфейсы

```bash
make paper-small
```

Expected outputs:

```text
runs/paper-small/synthetic/metrics.csv
runs/paper-small/weak-ifbench/metrics.csv
runs/paper-small/weak-ifbench/traces.jsonl
```

### Implementation notes

Target должен работать на чистой машине без модели и без интернета. Использовать mock-provider. Это не доказывает качество метода, но доказывает, что pipeline вообще жив.

### Unit tests

Не применимо.

### Integration tests

`make paper-small` in CI/local.

### Definition of Done (DoD)

- Target runs end-to-end.
- Generates metrics and traces.
- Finishes under 2 minutes on laptop.

---
