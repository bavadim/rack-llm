# T-030. Вынести `Agenda` в отдельный интерфейс

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Создать абстракцию `Agenda` для frontier search, чтобы можно было переключать реализацию между baseline list-agenda и heap-agenda без изменения Gumbel sampler.

### В скоупе

- `sampling/agenda.rkt`.
- Interface: empty, push, pop-max, size, empty?.
- `list-agenda` как baseline для абляции.
- Unit tests на порядок извлечения.

### Не в скоупе

- Heap implementation.
- Gumbel sampler rewrite.
- Benchmarks.

### Публичные интерфейсы

```racket
(struct agenda-item
  ([priority : Flonum]
   [payload : Any])
  #:transparent)

(define-type Agenda Any)

(: agenda-empty (-> Symbol Agenda))
(: agenda-push (-> Agenda agenda-item Agenda))
(: agenda-pop-max (-> Agenda (Values agenda-item Agenda)))
(: agenda-empty? (-> Agenda Boolean))
(: agenda-size (-> Agenda Natural))
```

### Implementation notes

Интерфейс должен быть функциональным: `push` и `pop-max` возвращают новую agenda. Внутри heap может быть mutable vector, но наружу это не вылезает.

### Unit tests

```racket
(define a0 (agenda-empty 'list))
(define a1 (agenda-push a0 (agenda-item 1.0 'a)))
(define a2 (agenda-push a1 (agenda-item 3.0 'b)))
(define-values (i a3) (agenda-pop-max a2))
(check-equal? (agenda-item-payload i) 'b)
(check-equal? (agenda-size a3) 1)
```

### Integration tests

- Existing sampler can run with `list-agenda` after adapter.

### Definition of Done (DoD)

- Agenda interface exists.
- List baseline implemented.
- Tests cover empty agenda error, ties, size.

---
