# T-040. Реализовать минимальный `Rule` API

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить модуль `rules/rule.rkt`, где программные эвристики применяются к готовому кандидату или структурированному объекту и возвращают `accept/reject/abstain` плюс диагностику.

### В скоупе

- `RuleDecision`.
- `RuleResult`.
- `Rule` как функция.
- Metadata и cost fields.
- Helpers для создания правил.

### Не в скоупе

- Dawid–Skene.
- Rule combinators.
- IFBench-specific heuristics.
- Token-level rule hooks.

### Публичные интерфейсы

```racket
(define-type RuleDecision (U 'accept 'reject 'abstain))

(struct rule-result
  ([decision : RuleDecision]
   [message : (Option String)]
   [metadata : (HashTable Symbol Any)]
   [cost-ms : Nonnegative-Flonum])
  #:transparent)

(struct rule
  ([id : Symbol]
   [description : String]
   [scope : Symbol]
   [run : (-> Any rule-result)])
  #:transparent)

(: accept (->* () (#:message (Option String) #:metadata (HashTable Symbol Any)) rule-result))
(: reject (->* () (#:message (Option String) #:metadata (HashTable Symbol Any)) rule-result))
(: abstain (->* () (#:message (Option String) #:metadata (HashTable Symbol Any)) rule-result))
(: apply-rule (-> rule Any rule-result))
```

### Implementation notes

`Rule` принимает `Any`, потому что rules могут работать с text, JSON-object, function-call object, evidence-matrix. Для типобезопасности конкретные наборы правил можно оборачивать в typed constructors.

### Unit tests

```racket
(define r (rule 'non-empty "reject empty strings" 'candidate
                (lambda (x) (if (and (string? x) (not (string=? x "")))
                                (accept)
                                (reject #:message "empty")))))
(check-equal? (rule-result-decision (apply-rule r "x")) 'accept)
(check-equal? (rule-result-decision (apply-rule r "")) 'reject)
```

### Integration tests

- Acceptance engine can run a list of rules against a candidate text.

### Definition of Done (DoD)

- Rule API stable and documented.
- Unit tests cover all 3 decisions.
- Rule diagnostics appear as data, not stdout.

---
