# T-032. Реализовать optional `pairing-heap-agenda`

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P2  
**Timebox:** 5 рабочих дней

### SMART goal

Реализовать pairing heap как optional agenda backend и сравнить с binary heap на Gumbel frontier workloads. Оставить в библиотеке только если benchmark показывает практический выигрыш.

### В скоупе

- `sampling/pairing-heap-agenda.rkt`.
- Амортизированная `O(1)` вставка.
- `O(log F)` amortized pop-max.
- Benchmark table.

### Не в скоупе

- Fibonacci heap.
- Теоретическая статья про heaps.

### Публичные интерфейсы

```racket
(agenda-empty 'pairing-heap)
```

### Implementation notes

Pairing heap может быть чисто функциональным деревом:

```racket
(struct heap-node ([item : agenda-item] [children : (Listof heap-node)]) #:transparent)
```

Merge — сравнение roots, loser становится child winner. Pop-max — pairwise merge children.

### Unit tests

Такие же как для binary heap плюс randomized equivalence:

```racket
(for ([xs random-priority-lists])
  (check-equal? (pop-all (build 'pairing-heap xs))
                (sort xs >)))
```

### Integration tests

- `agenda-bench` сравнивает list, binary, pairing.

### Definition of Done (DoD)

- Pairing heap либо принят и документирован, либо удален с сохранением benchmark result в `docs/agenda-decision.md`.

---
