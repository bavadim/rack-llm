# T-042. Реализовать hard-rule acceptance

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Добавить acceptance engine, который немедленно отклоняет кандидата при reject от hard-rule и передает soft-rule outputs дальше в scoring/calibration.

### В скоупе

- `rules/acceptance.rkt`.
- Hard rules.
- Soft rule collection.
- Acceptance diagnostics.

### Не в скоупе

- Dawid–Skene.
- Resampling loop.
- Prompt repair.

### Публичные интерфейсы

```racket
(struct rule-observation
  ([rule-id : Symbol]
   [decision : RuleDecision]
   [message : (Option String)]
   [metadata : (HashTable Symbol Any)])
  #:transparent)

(struct acceptance-input
  ([candidate : Any]
   [rules : (Listof weighted-rule)])
  #:transparent)

(struct acceptance-report
  ([hard-passed? : Boolean]
   [observations : (Listof rule-observation)]
   [diagnostics : (Listof String)])
  #:transparent)

(: run-rules (-> acceptance-input acceptance-report))
```

### Implementation notes

Даже если hard-rule отклонил candidate, можно либо остановиться сразу, либо собрать все diagnostics. Добавить config:

```racket
#:collect-all-hard-diagnostics? Boolean
```

Default: collect all hard diagnostics for trace, потому что одно сообщение об ошибке — это приглашение к следующему багу.

### Unit tests

```racket
(define report (run-rules (acceptance-input bad-json (list (hard json-rule) (soft style-rule)))))
(check-false (acceptance-report-hard-passed? report))
(check-true (member 'json-valid (map rule-observation-rule-id (acceptance-report-observations report))))
```

### Integration tests

- Gumbel candidate rejected by hard JSON rule does not reach DS scoring.

### Definition of Done (DoD)

- Hard/soft behavior deterministic.
- Observations serializable.
- Diagnostics included in trace.

---
