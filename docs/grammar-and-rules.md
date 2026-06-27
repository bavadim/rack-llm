# Grammar vs Rules

Grammar combinators describe which strings can be generated or accepted by the
decoder. Rule combinators aggregate checks over completed candidates.

| Concept | Module | Example | Meaning |
| --- | --- | --- | --- |
| Grammar repetition | `rack-llm/grammar/combinators` | `(one-or-more g)` | repeat a grammar fragment |
| Rule aggregation | `rack-llm/rules/combinators` | `rule-at-least(k, rs)` | accept when enough rules accept |

The naming boundary is intentional: `one-or-more` belongs to the grammar DSL,
while `rule-at-least` belongs to post-generation acceptance. The public API must
not expose an `at_least_ones` compatibility alias.

## Grammar Combinators

`rack-llm/grammar/combinators` exports a small regular grammar DSL:

- `seq`, `choice`, `optional`
- `zero-or-more`, `one-or-more`, `repeat`
- `sep-by`, `regex`, `capture`
- `grammar-accepts?` and `grammar->strings` for small tests and examples

The repetition helpers are intentionally bounded in this release. Use
`repeat`/`sep-by` with explicit limits for experiment grammars where the search
budget must stay auditable.

```racket
(require rack-llm/grammar
         rack-llm/grammar/combinators)

(define digits (sep-by (regex "[0-9]") (lit ",") 1 3))

(grammar-accepts? digits "1,2,3") ; #t
(grammar-accepts? digits "1,2,3,4") ; #f
```

`rack-llm/grammar/json` provides ordered `json_schema-lite` helpers for common
structured outputs: `json-object`, `json-array`, `json-string`, `json-number`,
`json-boolean`, and `json-enum`. It is not a JSON Schema implementation; object
fields are matched in the declared order.

```racket
(require rack-llm/grammar/json)

(define response
  (json-object
   (list (json-field "status" (json-enum '("ok" "error")) #t)
         (json-field "retry" json-boolean #t))))
```

`rack-llm/grammar/incremental-matcher` exposes `compile-matcher`,
`matcher-start`, `matcher-advance`, `matcher-viable?`, `matcher-accepting?`,
`matcher-text`, and `matcher-captures`. Tokens are appended as strings, so a
single provider token may contain multiple characters.

`rack-llm/grammar/mask` turns matcher state into a vocabulary mask:
`allowed-token?`, `allowed-token-mask`, `mask-logits`, and
`normalize-masked-logits`. Forbidden logits become `-inf.0`; normalized logits
are log-probabilities whose exponentiated allowed mass sums to 1.

`compile-grammar/check` returns structured `grammar-diagnostic` values for
empty choices, impossible repeats, duplicate captures, and unsupported regex
features such as lookbehind and backreferences.

## Minimal Rule API

Rules operate on completed candidates or decoded objects. They return
diagnostics as data:

```racket
(require rack-llm/rules/rule)

(define non-empty
  (rule 'non-empty
        "reject empty strings"
        'candidate
        (lambda (x)
          (if (and (string? x) (not (string=? x "")))
              (accept)
              (reject #:message "empty")))))

(apply-rule non-empty "text")
```

## Rule Combinators

Rule combinators are pure functions over completed-candidate rule outputs:

- `all-of`: reject if any child rejects; accept if all accept; otherwise abstain.
- `any-of`: accept if any child accepts; reject if all reject; otherwise abstain.
- `at-least`: accept when at least `k` children accept; reject when that is no
  longer possible; otherwise abstain.
- `exactly`: accept when exactly `k` children accept and no undecided child can
  change that; reject when exactly `k` is impossible.
- `none-of`: accept when all children reject; reject if any child accepts.
- `implies`: if the antecedent accepts, return the consequent decision;
  otherwise abstain.

Each combined result stores child rule ids and child decisions in metadata.

Use `hard` and `soft` to mark rules before running the acceptance engine. Hard
rules gate candidates; soft rules continue downstream to scoring and
calibration.

```racket
(require rack-llm/rules/acceptance
         rack-llm/rules/combinators)

(run-rules
 (acceptance-input candidate
                   (list (hard json-valid)
                         (soft style-score #:weight 0.5))))
```
