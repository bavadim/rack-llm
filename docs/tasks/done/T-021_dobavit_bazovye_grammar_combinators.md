# T-021. Добавить базовые grammar combinators

**Category:** Grammar DSL, комбинаторы и matcher  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить минимальный набор grammar combinators, достаточный для JSON-like и IFBench-ответов: `seq`, `choice`, `optional`, `zero-or-more`, `one-or-more`, `repeat`, `sep-by`, `regex`, `capture`.

### В скоупе

- Реализовать комбинаторы поверх текущих `lit`, `gen`, `select` или нового AST.
- Сохранить старые `lit`, `gen`, `select`.
- Добавить named captures для структурированного результата.

### Не в скоупе

- Полный JSON Schema.
- Semantic predicates внутри grammar.
- Backtracking optimization.

### Публичные интерфейсы

```racket
(: seq (-> expr * expr))
(: choice (-> expr (Listof expr) expr))
(: optional (-> expr expr))
(: zero-or-more (-> expr expr))
(: one-or-more (-> expr expr))
(: repeat (-> expr Natural Natural expr))
(: sep-by (-> expr expr Natural Natural expr))
(: regex (-> String expr))
(: capture (-> Symbol expr expr))
```

### Implementation notes

Минимальный вариант может компилировать комбинаторы в существующие `expr`. Если текущая модель `expr` неудобна, ввести новый internal AST и compatibility layer.

`regex` на первом этапе можно ограничить регулярными языками без lookbehind/backrefs. Это не PCRE-казино.

### Unit tests

```racket
(define g (seq (lit "a") (optional (lit "b")) (lit "c")))
(check-equal? (grammar->strings g #:max-depth 4) '("ac" "abc"))

(define g2 (sep-by (regex "[0-9]") (lit ",") 1 3))
(check-true (grammar-accepts? g2 "1"))
(check-true (grammar-accepts? g2 "1,2,3"))
(check-false (grammar-accepts? g2 "1,2,3,4"))
```

### Integration tests

- Build small grammar for JSON array of 1–3 strings.
- Generate with mock-provider and assert all outputs match accepted language.

### Definition of Done (DoD)

- Все перечисленные комбинаторы экспортированы.
- Есть тесты на empty, one, many, invalid.
- Старые примеры `lit/select/gen` не сломаны.

---
