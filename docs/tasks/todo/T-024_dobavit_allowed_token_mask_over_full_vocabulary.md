# T-024. Добавить allowed-token mask over full vocabulary

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Для заданного `matcher-state` и provider vocabulary вычислять маску допустимых токенов: token allowed, если `matcher-advance` оставляет state viable.

### В скоупе

- Функция `allowed-token-mask`.
- Поддержка full vocabulary.
- Поддержка top-K candidate list.
- Cache для repeated states.

### Не в скоупе

- Trie optimization.
- GPU mask.
- Byte-level tokenizer special cases кроме тестовых.

### Публичные интерфейсы

```racket
(: allowed-token? (-> matcher matcher-state String Boolean))
(: allowed-token-mask (-> matcher matcher-state (Vectorof String) (Vectorof Boolean)))
(: mask-logits (-> LogitVector (Vectorof Boolean) LogitVector))
(: normalize-masked-logits (-> LogitVector LogitVector))
```

### Implementation notes

`mask-logits` должен ставить `-inf` или очень малое значение запрещенным токенам. Нормализация должна быть numerically stable через log-sum-exp.

Cache key: `(grammar-state-id, token-id)` или hash от state. На первом этапе можно без сложного cache, но API оставить.

### Unit tests

```racket
(define vocab '#("a" "b" "c"))
(define m (compile-matcher (choice (lit "a") (list (lit "b")))))
(define mask (allowed-token-mask m (matcher-start m) vocab))
(check-equal? mask '#(#t #t #f))

(define logits '#(0.0 0.0 0.0))
(define q (normalize-masked-logits (mask-logits logits mask)))
(check-= (sum-softmax q) 1.0 1e-8)
```

### Integration tests

- With mock-provider uniform logits and grammar `(select "a" "b")`, generated candidates never include `c`.

### Definition of Done (DoD)

- Masking works for full vocabulary and top-K.
- Forbidden tokens have zero probability after normalization.
- Allowed probabilities sum to 1 within tolerance.

---
