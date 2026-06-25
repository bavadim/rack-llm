# T-031. Реализовать `binary-heap-agenda`

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Заменить линейную вставку во фронт на binary heap с `push/pop-max` за `O(log F)`, где `F` — размер фронта.

### В скоупе

- `sampling/binary-heap-agenda.rkt`.
- Max-heap by priority.
- Tie-breaker by insertion order для deterministic behavior.
- Benchmarks vs list-agenda.

### Не в скоупе

- Полностью константный `pop-max`.
- Pairing heap.
- Lock-free queue.

### Публичные интерфейсы

Через общий `Agenda` API:

```racket
(agenda-empty 'binary-heap)
```

### Implementation notes

Для arbitrary floating priorities нельзя обещать и `push`, и `pop-max` за `O(1)`. Реалистичная цель: binary heap `O(log F)`. Если нужна амортизированная `O(1)` вставка, отдельная задача на pairing heap, но `pop-max` все равно `O(log F)`. Математика, к сожалению, не подчиняется дедлайну.

### Unit tests

```racket
(define a (for/fold ([a (agenda-empty 'binary-heap)]) ([p '(5.0 1.0 3.0)])
            (agenda-push a (agenda-item p p))))
(define-values (i1 a1) (agenda-pop-max a))
(define-values (i2 a2) (agenda-pop-max a1))
(check-equal? (agenda-item-priority i1) 5.0)
(check-equal? (agenda-item-priority i2) 3.0)
```

Tie-breaker test:

```racket
; same priority -> earlier inserted first
```

### Integration tests

Benchmark fixture:

```bash
racket benchmarks/agenda-bench.rkt --sizes 1000,10000,100000
```

Acceptance:

- heap faster than list for `F >= 10000`.
- push/pop count and order deterministic.

### Definition of Done (DoD)

- Binary heap is default agenda for Gumbel sampler.
- List agenda remains as baseline.
- Complexity docs mention `O(log F)`.

---
