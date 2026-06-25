# T-071. Написать `docs/complexity.md`

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Описать асимптотическую сложность алгоритма через измеряемые counters: `N`, `E`, `F`, `R`, `C_LLM`, `C_G`, `C_H`, `I`, `M`, `H`.

### В скоупе

- Complexity of Gumbel stream with heap.
- Complexity of incremental matcher.
- Complexity of Dawid–Skene fit/predict.
- Difference between old list-agenda and heap-agenda.

### Не в скоупе

- Формальное доказательство Gumbel exactness.
- GPU runtime model.

### Публичные интерфейсы

Документ:

```text
docs/complexity.md
```

Основная формула:

```text
T = O(N*C_LLM + E*C_G + (N+E)*log F + R*C_H)
T_DS = O(I*M*H)
Memory = O(F + C_cache)
```

### Implementation notes

Прямо написать: старая отсортированная list-agenda дает лишнюю линейную вставку. Новая heap-agenda дает `O(log F)` push/pop. Не обещать `O(1)` pop-max.

### Unit tests

Не применимо.

### Integration tests

- Complexity table generator uses same symbols.

### Definition of Done (DoD)

- Документ готов для переноса в статью.
- Формулы совпадают с counters в trace.

---
