# T-011. Реализовать deterministic mock-provider

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 2 рабочих дня

### SMART goal

Реализовать deterministic provider для unit tests и synthetic experiments: он должен выдавать заранее заданные full logits для заданного префикса и поддерживать маленький словарь.

### В скоупе

- `providers/mock-provider.rkt`.
- Таблица `prefix -> logits`.
- Default logits для неизвестного prefix.
- Детерминированная токенизация для односимвольного и строкового словаря.

### Не в скоупе

- BPE tokenization.
- KV cache.
- Stochastic generation.

### Публичные интерфейсы

```racket
(: make-mock-provider
   (->* (#:vocab (Listof String)
         #:default-logits LogitVector)
        (#:prefix-logits (HashTable String LogitVector)
         #:model-id String)
        provider))
```

### Implementation notes

Mock-provider должен быть тупым и надежным: строковый prefix склеивается из `detokenize`, затем ищется в hash. Это не LLM, это лабораторная крыса для алгоритмов.

### Unit tests

```racket
(define p (make-mock-provider
           #:vocab '("a" "b" "<eos>")
           #:default-logits '#(0.0 0.0 -10.0)
           #:prefix-logits (hash "a" '#(-10.0 0.0 0.0))))
(check-equal? (vector-ref (logits-result-logits ((provider-next-logits p) '() "a" (provider-initial-state p))) 1) 0.0)
```

### Integration tests

- Synthetic Gumbel test uses mock-provider only.
- No external process or network required.

### Definition of Done (DoD)

- Mock-provider passes unit tests.
- Used by at least one sampler test and one grammar test.

---
