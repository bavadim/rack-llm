# T-060. Описать протокол Weak-IFBench

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 2 рабочих дня

### SMART goal

Создать `docs/weak-ifbench.md`, где формально описан эксперимент: вход, weak heuristics, gold verifier, budget, output, метрики и baselines.

### В скоупе

- Формальная постановка.
- Что видит метод и что скрыто.
- Main metrics.
- Baselines.
- Data split.

### Не в скоупе

- Код runner-а.
- Реализация эвристик.

### Публичные интерфейсы

Документ:

```text
docs/weak-ifbench.md
```

### Implementation notes

Ключевая фраза:

```text
Gold verifier is never used for candidate selection; it is used only for evaluation.
```

Без этого ограничения возможна утечка gold-verifier в процедуру выбора кандидата, что делает эксперимент некорректным.

### Unit tests

Не применимо.

### Integration tests

Не применимо.

### Definition of Done (DoD)

- Документ есть.
- Определены `GoldSuccess@B`, `Oracle@B`, `SelectionEfficiency@B`.
- Определено, как обучается DS без gold на calibration split.

---
