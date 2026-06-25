# T-033. Реализовать top-down Gumbel-stream

**Category:** Agenda, Gumbel-stream и сложность  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 10 рабочих дней

### SMART goal

Реализовать ленивый Gumbel-stream, который перечисляет завершенные кандидаты по Gumbel-priority без возвращения, используя provider logits, grammar mask и heap agenda.

### В скоупе

- `sampling/gumbel-stream.rkt`.
- Узел фронта: prefix tokens/text, matcher state, logprob, gumbel priority, depth, provider state.
- Ленивая sequence/stream of candidates.
- Budget: max candidates, max expanded nodes, max depth, max wall-time.
- Deterministic seed.

### Не в скоупе

- Proof of exactness in code.
- Repair prompts.
- Dawid–Skene.
- Semantic rules.

### Публичные интерфейсы

```racket
(struct gumbel-config
  ([max-depth : Natural]
   [max-candidates : Natural]
   [max-expanded-nodes : Natural]
   [seed : Integer]
   [agenda-kind : Symbol]
   [dedupe : (Listof Symbol)])
  #:transparent)

(struct candidate
  ([text : String]
   [tokens : (Listof TokenId)]
   [logprob : Flonum]
   [gumbel-score : Flonum]
   [matcher-state : matcher-state]
   [provider-traces : (Listof provider-trace)])
  #:transparent)

(: gumbel-stream
   (-> provider matcher gumbel-config EvaluatedProgram (Sequenceof candidate)))
```

### Implementation notes

Минимальная схема:

1. Начальный узел: empty prefix, matcher-start, logprob 0.
2. Pop узел с максимальным Gumbel priority.
3. Если matcher accepting — yield candidate.
4. Иначе запросить logits у provider.
5. Маскировать недопустимые токены.
6. Для допустимых токенов создать child nodes.
7. Присвоить Gumbel priorities через корректный seeded random stream.
8. Push children в agenda.

Важный момент: если используется approximate Gumbel process, это должно быть явно указано в docs и synthetic tests. Не надо объявлять exact то, что является priority search approximation. Рецензенты не всегда спят.

### Unit tests

С mock-provider и grammar с конечным пространством:

```racket
(define p (make-mock-provider ...))
(define m (compile-matcher (choice (lit "a") (list (lit "b") (lit "c")))))
(define ys (stream->list (gumbel-stream p m (gumbel-config ... #:max-candidates 3) '())))
(check-equal? (length ys) 3)
(check-equal? (remove-duplicates (map candidate-text ys)) (map candidate-text ys))
(for ([y ys]) (check-true (matcher-accepting? (candidate-matcher-state y))))
```

Determinism:

```racket
(check-equal? (run-with-seed 42) (run-with-seed 42))
(check-not-equal? (run-with-seed 42) (run-with-seed 43))
```

### Integration tests

- Synthetic finite grammar compares stream order against explicit enumeration with sampled Gumbels for the same seed.
- Duplicate rate = 0 at token-sequence level.

### Definition of Done (DoD)

- Stream lazy: first candidate does not enumerate whole tree.
- Uses heap agenda by default.
- No invalid grammar outputs.
- Deterministic under seed.

---
