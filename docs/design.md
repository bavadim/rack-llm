# Design

The core is typed and token-native:

```text
tokenizer : text <-> token ids
provider  : prompt ids + prefix ids -> logits view
filter    : state + token id -> next state
generate  : model + prompt text + filter builder -> generated text
```

Text appears at the edges: builders use a tokenizer to compile literals,
watchers, and regex patterns into token-aware filters; generation itself uses
token ids and private logits views.

## Filters

Filter runtime internals live in `private/filter.rkt`. Filters are small state
machines with common protocol functions. Hard constraints kill transitions.
Soft constraints contribute score and potential.

Sampling internals live in `private/sampling.rkt`. The default sampler uses:

```text
lm_logit + beta * (delta_score + lambda * delta_potential)
```

This keeps hard and soft behavior in one scoring path.

Exact full-vocabulary soft decoding scans every finite logit. This is the
correct semantics for paper-grade exact mode, but Qwen-scale open text watchers
still need a dedicated optimization pass or a fail-closed infeasible decision.
Top-k benchmark artifacts are useful engineering evidence, not exact-mode
claims.

## Regex

Regex internals live in `private/regex.rkt`. Patterns are parsed and compiled
to tokenizer-independent NFAs when `rx` is constructed; token-specific
transition caches are created when a tokenizer is applied:

```text
regex source -> regex AST -> NFA -> token texts -> lazy DFA cache
```

The generation hot path is token based. Regex machines keep token transition
caches so generation can ask which token ids keep the current state alive.

## Public Boundary

`rack-llm` exports the user-facing DSL, `Model`, model metadata/close helpers,
result structs, and `generate`. Tokenizer/provider constructors, logits views,
filter runtime types, and sampling protocol functions stay in private modules
so user code cannot depend on internal state layout.

## Architecture Lint

`make dep-lint` prints a compact report for the core modules: line count,
direct local dependencies, fan-in/fan-out, and public surface size. Size budget
overruns are warnings so they can start an architecture discussion without
blocking small changes.

The same command fails on hard boundary violations: local dependency cycles,
private modules depending on public facades, tests importing private modules,
known internals leaking from `main.rkt`, and actionable unused `require`s after
filtering Typed Racket contract noise. Experiment scripts are intentionally
outside the strict core graph; they are benchmark drivers, not part of the
library architecture contract.

Package dependency checks are available after installing the package:

```sh
raco setup --no-docs --check-pkg-deps --unused-pkg-deps --pkgs rack-llm
```
