# T-062. Реализовать weak heuristic templates для IFBench constraints

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 8 рабочих дней

### SMART goal

Для основных constraint types IFBench реализовать набор слабых эвристик, каждая возвращает `accept/reject/abstain`, чтобы метод мог выбирать кандидата без доступа к gold verifier.

### В скоупе

Минимум для первого релиза:

- word count.
- sentence count.
- phrase presence.
- forbidden phrase.
- section/header format.
- JSON/Markdown structure.

Для каждого типа: 2–4 слабые эвристики с разной точностью.

### Не в скоупе

- Полное покрытие всех 58 types сразу.
- LLM-judge эвристики.
- Multilingual perfect handling.

### Публичные интерфейсы

```racket
(: weak-rules-for-constraint (-> constraint-spec (Listof weighted-rule)))
(: weak-rules-for-task (-> ifbench-task (Listof weighted-rule)))
```

Пример rule ids:

```text
word-count/split
word-count/tokenizer
word-count/regex
phrase-presence/lowercase
forbidden-phrase/word-boundary
format/markdown-headings
```

### Implementation notes

Слабая эвристика должна быть правдоподобно несовершенной. Например:

- `split()` word count ошибается на punctuation/code.
- regex phrase check ошибается на Unicode normalization.
- sentence split by `.?!` ошибается на abbreviations.

Именно эти ошибки нужны, чтобы проверять Dawid–Skene, а не победу над соломенным majority baseline.

### Unit tests

Word count:

```racket
(define r (make-word-count-split-rule 'wc 10))
(check-equal? (decision (apply-rule r "one two")) 'reject)
(check-equal? (decision (apply-rule r ten-word-string)) 'accept)
```

Forbidden phrase:

```racket
(check-equal? (decision (apply-rule forbidden-rule "no bad word")) 'reject)
(check-equal? (decision (apply-rule forbidden-rule "clean text")) 'accept)
```

Abstain:

```racket
(check-equal? (decision (apply-rule word-count-rule "```code block```")) 'abstain)
```

### Integration tests

- For fixture tasks, `weak-rules-for-task` returns non-empty rules.
- Applying rules to known good/bad answers produces a mix of accept/reject/abstain.

### Definition of Done (DoD)

- At least 6 constraint groups supported.
- Each supported group has at least 2 weak rules.
- Tests include accept, reject, abstain.
- Coverage report shows unsupported constraints as explicit skipped, not silent pass.

---
