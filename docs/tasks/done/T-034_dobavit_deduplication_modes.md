# T-034. Добавить deduplication modes

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Добавить дедупликацию кандидатов на трех уровнях: token sequence, final string, normalized object. По умолчанию включить token-sequence dedupe, string dedupe опционально.

### В скоупе

- `sampling/dedupe.rkt`.
- Hash token sequence.
- Hash final string.
- Hook for normalized object key.

### Не в скоупе

- Semantic equivalence.
- Embedding-based dedupe.

### Публичные интерфейсы

```racket
(define-type DedupeMode (U 'tokens 'string 'object))
(define-type ObjectKeyer (-> candidate (Option String)))

(: make-dedupe-filter (-> (Listof DedupeMode) (Option ObjectKeyer) (-> candidate Boolean)))
```

### Implementation notes

Функция фильтра возвращает `#t`, если кандидат новый. Внутри может быть mutable hash set, но наружный интерфейс — маленькая функция.

### Unit tests

```racket
(define f (make-dedupe-filter '(string) #f))
(check-true (f (candidate "a" '(1) ...)))
(check-false (f (candidate "a" '(2) ...)))
```

### Integration tests

- With provider that can produce two tokenizations for same string, string dedupe removes duplicate.

### Definition of Done (DoD)

- Dedup modes documented.
- Metrics include duplicate counts.

---
