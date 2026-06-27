# T-025. Добавить grammar compile diagnostics

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

Добавить понятные ошибки компиляции grammar: unsupported regex, impossible repeat, duplicate capture names, empty choice.

### В скоупе

- Structured `grammar-error`.
- Diagnostics with path to subexpression.
- Tests for common errors.

### Не в скоупе

- IDE integration.
- Pretty printer for every AST node.

### Публичные интерфейсы

```racket
(struct grammar-diagnostic
  ([code : Symbol]
   [message : String]
   [path : (Listof Natural)])
  #:transparent)

(: compile-grammar/check (-> expr (U matcher (Listof grammar-diagnostic))))
```

### Implementation notes

Пусть compile либо возвращает matcher, либо diagnostics. Не надо печатать предупреждения в stdout. stdout не мусорное ведро.

### Unit tests

```racket
(check-match (compile-grammar/check (choice)) [(list (? grammar-diagnostic?)) _])
(check-match (compile-grammar/check (repeat (lit "x") 3 2)) [(list d) _])
```

### Integration tests

- JSON helper with invalid schema returns diagnostic, not crash.

### Definition of Done (DoD)

- Top 5 grammar mistakes covered by tests.
- Error messages include task-relevant text.
