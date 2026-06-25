# T-022. Реализовать JSON helpers

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить JSON helpers для описания типичных structured outputs без ручной сборки кавычек и скобок.

### В скоупе

- `json-object`, `json-array`, `json-string`, `json-number`, `json-boolean`, `json-enum`.
- Required fields.
- Optional fields.
- Ordered object mode на первом этапе.
- Captures для полей.

### Не в скоупе

- Полный JSON Schema draft.
- Arbitrary nesting optimization.
- Unicode-perfect JSON string escaping beyond needed tests.

### Публичные интерфейсы

```racket
(struct json-field
  ([name : String]
   [grammar : expr]
   [required? : Boolean])
  #:transparent)

(: json-object (-> (Listof json-field) expr))
(: json-array (-> expr Natural Natural expr))
(: json-string (->* () (#:max-chars Natural #:pattern (Option String)) expr))
(: json-number expr)
(: json-boolean expr)
(: json-enum (-> (Listof String) expr))
```

### Implementation notes

Сначала ordered JSON. Не надо начинать с произвольного порядка полей: это взорвет grammar state. Для BFCL/Weak-IFBench ordered output чаще достаточно.

### Unit tests

```racket
(define g (json-object
           (list (json-field "status" (json-enum '("ok" "error")) #t)
                 (json-field "retry" json-boolean #t))))
(check-true (grammar-accepts? g "{\"status\":\"ok\",\"retry\":true}"))
(check-false (grammar-accepts? g "{\"status\":\"wat\",\"retry\":true}"))
```

### Integration tests

- Generate 20 candidates with mock-provider; all parse as JSON.
- Captured fields match JSON parser result.

### Definition of Done (DoD)

- JSON helpers покрыты unit tests.
- Есть пример `examples/json-decision.rkt`.
- Документация честно пишет, что это `json_schema-lite`, не полный JSON Schema.

---
