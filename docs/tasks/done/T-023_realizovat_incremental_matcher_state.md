# T-023. Реализовать incremental matcher state

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 8 рабочих дней

### SMART goal

Заменить replay-style matcher на incremental matcher: добавление токена должно обновлять состояние на основе предыдущего `MatcherState`, а не повторно парсить весь накопленный префикс.

### В скоупе

- `grammar/incremental-matcher.rkt`.
- `matcher-start`, `matcher-advance`, `matcher-viable?`, `matcher-accepting?`.
- Сохранение captures.
- Совместимость со старым matcher API через wrapper.

### Не в скоупе

- Оптимальный parser generator.
- Поддержка всех regex-фич.
- Semantic predicates.

### Публичные интерфейсы

```racket
(struct matcher-state
  ([grammar-id : Symbol]
   [position : Any]
   [captures : (HashTable Symbol String)]
   [text : String]
   [viable? : Boolean]
   [accepting? : Boolean])
  #:transparent)

(: compile-matcher (-> expr matcher))
(: matcher-start (-> matcher matcher-state))
(: matcher-advance (-> matcher matcher-state String matcher-state))
(: matcher-viable? (-> matcher-state Boolean))
(: matcher-accepting? (-> matcher-state Boolean))
(: matcher-text (-> matcher-state String))
(: matcher-captures (-> matcher-state (HashTable Symbol String)))
```

### Implementation notes

Начать с маленького NFA-style internal representation. Для `lit`, `choice`, `repeat`, `regex` можно держать множество active states. Это функционально и прозрачно. Если performance будет плохой, оптимизировать позже.

Важно: token может быть строкой из нескольких символов. Matcher должен добавлять именно token string, не char.

### Unit tests

```racket
(define m (compile-matcher (seq (lit "a") (choice (lit "b") (list (lit "c"))))))
(define s0 (matcher-start m))
(define s1 (matcher-advance m s0 "a"))
(check-true (matcher-viable? s1))
(check-false (matcher-accepting? s1))
(define s2 (matcher-advance m s1 "b"))
(check-true (matcher-accepting? s2))
(check-false (matcher-viable? (matcher-advance m s1 "x")))
```

Capture test:

```racket
(define m (compile-matcher (capture 'name (regex "[a-z]+"))))
(define s (foldl (lambda (tok st) (matcher-advance m st tok)) (matcher-start m) '("a" "b")))
(check-equal? (hash-ref (matcher-captures s) 'name) "ab")
```

### Integration tests

- Compare replay matcher and incremental matcher on the same small grammar for all strings up to length 4.
- Benchmark: long literal chain 1000 tokens; incremental must be at least 3x faster than replay.

### Definition of Done (DoD)

- Incremental matcher passes equivalence tests.
- Replay matcher no longer used in default sampler.
- Complexity docs updated: no extra prefix-length replay factor.

---
