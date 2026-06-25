# T-041. Реализовать rule combinators

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить функциональные комбинаторы правил: `all-of`, `any-of`, `at-least`, `exactly`, `none-of`, `implies`, `hard`, `soft`.

### В скоупе

- Rule combinators for `RuleResult` lists.
- Preserve diagnostics from child rules.
- Distinguish hard and soft rules.

### Не в скоупе

- Dawid–Skene weighting.
- Learning rule weights.
- Grammar combinators.

### Публичные интерфейсы

```racket
(: all-of (-> Symbol String (Listof rule) rule))
(: any-of (-> Symbol String (Listof rule) rule))
(: at-least (-> Symbol String Natural (Listof rule) rule))
(: exactly (-> Symbol String Natural (Listof rule) rule))
(: none-of (-> Symbol String (Listof rule) rule))
(: implies (-> Symbol String rule rule rule))

(struct weighted-rule
  ([rule : rule]
   [kind : (U 'hard 'soft)]
   [weight : (Option Flonum)])
  #:transparent)

(: hard (-> rule weighted-rule))
(: soft (->* (rule) (#:weight Flonum) weighted-rule))
```

### Implementation notes

Semantics:

- `all-of`: reject if any child rejects; accept if all accept; abstain otherwise.
- `any-of`: accept if any child accepts; reject if all reject; abstain otherwise.
- `at-least(k)`: accept if accepts >= k; reject if impossible to reach k; abstain otherwise.
- `implies(a,b)`: if `a` rejects/abstains -> abstain; if `a` accepts then result of `b`.

### Unit tests

```racket
(check-equal? (decision ((all-of 'r "" (list accept-rule reject-rule)) x)) 'reject)
(check-equal? (decision ((at-least 'r "" 2 (list accept-rule accept-rule reject-rule)) x)) 'accept)
(check-equal? (decision ((any-of 'r "" (list abstain-rule reject-rule)) x)) 'abstain)
```

### Integration tests

- Compose IFBench weak rules for word-count group.
- Diagnostics contain child rule ids.

### Definition of Done (DoD)

- All combinators tested.
- Docs distinguish these from grammar combinators.
- No hidden global weights.

---
