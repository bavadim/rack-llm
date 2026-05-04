# rack-llm

`rack-llm` is a small Racket library for programming with LLMs as ordinary Racket computation.

It is inspired by Guidance-style controlled generation, but the API is designed around Racket ideas:

- code is data;
- grammars are ordinary procedures;
- finite choices are computed by Racket code;
- reviewers are plain functions;
- best-of-N search is just another grammar combinator.

The rule of thumb:

```text
compute what can be computed
select what can be selected
constrain what can be constrained
review only what cannot be constructed locally
```

This scaffold currently ships an OpenAI-compatible `/v1/chat/completions` backend. Real token-level constrained decoding is intentionally isolated behind the grammar/backend boundary and can be implemented later for providers that expose grammar, regex, JSON Schema, or token-mask support.

## Install locally

From this repository:

```bash
raco pkg install --auto
raco test tests
```

Use it from another project:

```racket
#lang racket
(require rack-llm)
(require rack-llm/backends/openai-compatible)
```

## Configure an OpenAI-compatible provider

```bash
export OPENAI_API_KEY="..."
export OPENAI_BASE_URL="https://api.openai.com/v1"
export OPENAI_MODEL="gpt-4.1-mini"
```

```racket
(define model
  (make-openai-compatible-model
   #:model (or (getenv "OPENAI_MODEL") "gpt-4.1-mini")
   #:base-url (or (getenv "OPENAI_BASE_URL") "https://api.openai.com/v1")))
```

For local OpenAI-compatible servers, set `OPENAI_BASE_URL`, for example:

```bash
export OPENAI_BASE_URL="http://localhost:8000/v1"
export OPENAI_API_KEY="EMPTY"
```

## Core chat API

```racket
(run model program) -> result?
```

Runs a chat program against a model.

```racket
(chat part ...) -> procedure?
(system text) -> procedure?
(user text) -> procedure?
(assistant grammar) -> procedure?
```

Example:

```racket
(define res
  (run model
       (chat
        (system "Ты пишешь коротко.")
        (user "Скажи привет.")
        (assistant hello-g))))

(result-text res)
```

## Grammar API

### `define-grammar`

```racket
(define-grammar (name arg ...)
  body ...)
```

Defines a reusable grammar. Inside a grammar, ordinary Racket forms work normally:

```racket
define
let
cond
when
for/list
match
ordinary function calls
```

LLM operations such as `emit`, `gen`, `select`, and `pick` mutate the current generation state.

### `emit`

```racket
(emit value) -> string?
```

Appends deterministic text to the current candidate.

Use `emit` for anything Racket already knows.

```racket
(emit "SELECT ")
(emit (number->string n))
```

### `gen`

```racket
(gen #:as name
     #:max-tokens n
     #:regex rx
     #:grammar grammar-spec
     #:json-schema schema
     #:temperature t
     #:stop stop
     #:extra extra-hash)
```

Generates a free text fragment.

If `#:as` is provided, the generated string is captured under that symbol.

The OpenAI-compatible backend currently treats regex/grammar/schema constraints as prompt-level instructions and validates regex after generation. Future backends can compile these constraints to real token-level constrained decoding.

Example:

```racket
(define-grammar (label-g ctx)
  (gen #:as 'label
       #:regex #px"[^\n]{1,32}"
       #:max-tokens 12
       #:temperature 0.8))
```

### `select`

```racket
(select options
        #:as name
        #:show show-proc
        #:temperature t)
```

Lets the model choose one option from a finite set and emits the rendered value into the output.

Returns the original selected Racket value.

```racket
(define priority
  (select '("low" "medium" "high")
          #:as 'priority))
```

Object choice:

```racket
(define table
  (select tables
          #:as 'table
          #:show table-name))
```

This emits `(table-name table)` but captures and returns the original `table` object.

### `pick`

```racket
(pick options
      #:as name
      #:show show-proc
      #:temperature t)
```

Like `select`, but does not emit the selected value.

Use `pick` for hidden control choices.

```racket
(define table
  (pick (schema-tables schema)
        #:as 'table
        #:show table-name))

(emit "FROM ")
(emit (table-name table))
```

`pick` is how you move validity checks from reviewers into construction. If a table must exist, do not generate a table name and review it later. Pick it from the schema.

## Review API

Reviewers are ordinary functions:

```racket
;; Reviewer = Context Candidate -> Review
```

They return:

```racket
(pass #:score score #:reason reason #:hint hint #:data data)
(fail reason #:score score #:hint hint #:data data)
(abstain #:reason reason #:hint hint #:data data)
```

A reviewer should check one thing.

Good names:

```racket
no-dangling-ending
keeps-placeholders
query-returns-rows
claim-supported-by-span
```

Bad name:

```racket
is-good-answer?
```

That is not a reviewer. That is despair wearing a function name.

## Weighted reviewers

```racket
(weighted weight reviewer)
```

`weight` can be a number:

```racket
(weighted 3 no-dangling-ending)
```

or a function:

```racket
(weighted
 (lambda (ctx cand review)
   (if (hash-ref ctx 'strict? #f) 10 2))
 reviewer)
```

Reviewers detect.

Weights decide how much detection matters.

## `best-of`

```racket
(best-of grammar
         #:as name
         #:tries n
         #:context ctx
         #:reviewers reviewers
         #:weigh weigh
         #:min-score min-score
         #:on-fail on-fail)
```

Runs a grammar several times on isolated model-state branches, reviews every candidate, and returns the highest-scoring branch.

Defaults:

```racket
#:tries 4
#:context #f
#:reviewers '()
#:weigh weighted-score
#:min-score -inf.0
#:on-fail 'return-best
```

`#:on-fail` can be:

```racket
'return-best
'raise
```

Use `best-of` only for properties that cannot be enforced constructively.

Good uses:

```text
natural wording
semantic support
test execution result
SQL result usefulness
translation quality
non-triviality
```

Bad uses:

```text
valid enum
known source id
existing SQL column
required JSON field
allowed tool name
```

Those belong in `select`, `pick`, regex, JSON Schema, or grammar constraints.

## Complete UI label example

```racket
#lang racket

(require rack-llm
         rack-llm/backends/openai-compatible)

(define model
  (make-openai-compatible-model
   #:model (or (getenv "OPENAI_MODEL") "gpt-4.1-mini")
   #:base-url (or (getenv "OPENAI_BASE_URL") "https://api.openai.com/v1")))

(define-grammar (label-g ctx)
  (gen #:as 'label
       #:regex #px"[^\n]{1,32}"
       #:max-tokens 12
       #:temperature 0.8))

(define bad-endings
  (set "и" "или" "но" "а" "что" "чтобы" "для" "с" "в" "на" "по" "к"))

(define (no-dangling-ending ctx cand)
  (define words
    (string-split
     (string-downcase
      (string-trim (candidate-text cand) " .,!?;:"))))
  (cond
    [(null? words)
     (fail "empty label" #:hint "Сгенерируй непустую законченную фразу.")]
    [(set-member? bad-endings (last words))
     (fail "label ends with a dangling function word"
           #:hint "Не заканчивай фразу союзом или предлогом.")]
    [else
     (pass #:score 0.7)]))

(define (keeps-placeholders ctx cand)
  (define required (hash-ref ctx 'placeholders '()))
  (define missing
    (filter-not
     (lambda (p) (string-contains? (candidate-text cand) p))
     required))
  (if (null? missing)
      (pass #:score 1.0)
      (fail "missing placeholders"
            #:hint (format "Сохрани placeholders дословно: ~a" missing))))

(define ctx
  (hash 'placeholders '("{count}")))

(define res
  (run model
       (chat
        (system "Ты пишешь короткие UI labels на русском.")
        (user "Кнопка удаляет {count} выбранных файлов.")
        (assistant
         (best-of (label-g ctx)
                  #:as 'label
                  #:tries 8
                  #:context ctx
                  #:reviewers
                  (list
                   (weighted 2 no-dangling-ending)
                   (weighted 10 keeps-placeholders))
                  #:weigh weighted-score)))))

(displayln (result-ref res 'label))
```

## SQL sketch

```racket
(struct metric (name sql) #:transparent)
(struct table (name columns) #:transparent)

(define metrics
  (list (metric "revenue" "sum(amount)")
        (metric "orders_count" "count(*)")))

(define tables
  (list (table "orders" '("created_at" "amount" "customer_id"))))

(define-grammar (sql-g ctx)
  (emit "SELECT ")
  (define m
    (pick metrics #:as 'metric #:show metric-name))
  (emit (metric-sql m))
  (emit " FROM ")
  (define t
    (pick tables #:as 'table #:show table-name))
  (emit (table-name t))
  (emit " WHERE created_at >= ")
  (select '("'2026-01-01'" "'2026-04-01'" "'2026-05-01'")
          #:as 'date-from))
```

Do not review whether the table exists. It was picked from real tables.

Review what remains global:

```racket
(define (query-returns-rows ctx cand)
  (define db (hash-ref ctx 'db))
  (define rows
    (safe-execute-sql db (candidate-text cand) #:limit 1000))
  (cond
    [(sql-error? rows)
     (fail "SQL execution failed"
           #:hint "Выбери другой допустимый запрос.")]
    [(empty? rows)
     (fail "Query returned no rows"
           #:score -0.6
           #:hint "Проверь дату, метрику или фильтры.")]
    [else
     (pass #:score 1.0)]))
```

## Public API summary

Generation:

```racket
define-grammar
emit
gen
select
pick
```

Chat execution:

```racket
run
chat
system
user
assistant
result-text
result-ref
result-captures
```

Candidates:

```racket
candidate-text
candidate-ref
candidate-captures
candidate-trace
candidate-attempt
candidate-error
```

Review:

```racket
pass
fail
abstain
weighted
weighted-score
best-of
```

Backend:

```racket
make-openai-compatible-model
```

## Implementation notes

The current implementation is deliberately small:

```text
core.rkt       chat state, model abstraction, run/chat/system/user/assistant
grammar.rkt    define-grammar, emit, gen, select, pick, best-of
review.rkt     pass/fail/abstain, weighted reviewers, weighted-score
result.rkt     result/candidate structs and accessors
backends/      provider adapters
examples/      executable sketches
tests/         rackunit tests with a mock model
```

The OpenAI-compatible backend uses `POST /chat/completions`.

`gen`, `select`, and `pick` are implemented in a provider-neutral way for now. A later backend can replace prompt-level finite-choice and regex handling with true constrained decoding without changing the user-facing API.

## Design rules

### 1. Do not review what can be constructed

Wrong:

```racket
(gen #:as 'table)
```

Right:

```racket
(pick (schema-tables schema)
      #:as 'table
      #:show table-name)
```

### 2. Do not generate what Racket can compute

Wrong:

```racket
(gen #:as 'sql-prefix)
```

Right:

```racket
(emit "SELECT ")
```

### 3. Keep reviewers small

A reviewer checks one known failure mode.

### 4. Keep weighting separate

A reviewer says what happened.

A weight says how much it matters.

### 5. Keep the core functional

No global agent object. No pipeline manager. No suite class. No ceremony parade.

The whole idea is:

```racket
(assistant
 (best-of (some-grammar ctx)
          #:reviewers (list (weighted w reviewer) ...)))
```

If it gets harder than that, the library is already plotting against its users.
