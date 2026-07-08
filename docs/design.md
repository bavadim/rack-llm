# Design

The core is typed and token-native:

```text
tokenizer : text <-> token ids
provider  : prompt ids + prefix ids -> logits
filter    : state + token id -> next state
generate  : provider + prompt ids + filter -> token ids
```

Text appears at the edges: builders use a tokenizer to compile literals,
watchers, and regex patterns into token-aware filters; generation itself uses
token ids only.

## Filters

Filters are small state machines with common protocol functions. Hard
constraints kill transitions. Soft constraints contribute score and potential.

The sampler uses:

```text
lm_logit + beta * (delta_score + lambda * delta_potential)
```

This keeps hard and soft behavior in one scoring path.

## Regex

Regex internals live in `private/regex.rkt`. Patterns are parsed and compiled
to tokenizer-independent NFAs when `rx` is constructed; token-specific
transition caches are created when a tokenizer is applied:

```text
regex source -> regex AST -> NFA -> token texts -> lazy DFA cache
```

The generation hot path is token based. `filter-allowed-ids` asks the compiled
machine which token ids can leave the current DFA state alive.

## Public Boundary

`rack-llm` exports DSL constructors and protocol functions, not the raw
implementation structs behind them. This keeps user code from depending on
internal state layout while still allowing direct protocol tests.
