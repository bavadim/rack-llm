# Design

The core is typed and token-native:

```text
tokenizer : text <-> token ids
provider  : prompt ids + prefix ids -> logits view
guidance  : state + token id -> next state
generate  : model + prompt text + program -> generated text
```

Text appears at the edges: programs are compiled with a tokenizer into
token-aware guidance; generation itself uses token ids and private logits views.

## Programs

Guidance runtime internals live in `private/guidance.rkt`. Guidance values are small state
machines with common protocol functions. Hard constraints kill transitions.
Soft constraints contribute score and potential.

Sampling internals live in `private/sampling.rkt`. The default sampler uses:

```text
lm_logit + beta * (delta_score + lambda * delta_potential)
```

This keeps hard and soft behavior in one scoring path.

`private/cars.rkt` implements the exact alternative. Unknown subtrees have
envelope `1`, proven hard-invalid prefixes have `0`, and evaluated terminal
outputs retain their fractional Gibbs acceptance weight. Trie updates happen
after the proposal's acceptance decision, so every yielded output remains an
exact draw even while the proposal distribution adapts.

Exact full-vocabulary soft decoding scans every finite logit. This is the
correct semantics for paper-grade exact mode, but Qwen-scale open text observers
still need a dedicated optimization pass or a fail-closed infeasible decision.
Top-k benchmark artifacts are useful engineering evidence, not exact-mode
claims.

## Regex

Regex internals live in `private/regex.rkt` and the native PCRE2 boundary.
Patterns are compiled once per tokenizer-backed machine, while all machines in
one generation share a single native vocabulary:

```text
regex source -> PCRE2 code + shared token bytes -> residual state
```

The generation hot path is token based. A conservative consuming subset uses
PCRE2's restart workspace as the residual state. Workspace storage grows on
demand and is copied only from the selected parent state. Assertions,
boundaries, atomic/possessive constructs, `\\R`, and `\\X` replay the complete
prefix with the standard matcher so token boundaries cannot change the
language. Unsupported recursive or capture-dependent constructs are rejected
before generation.

## Public Boundary

`rack-llm` exports the user-facing DSL, `Model`, model metadata/close helpers,
result structs, and `generate`. Tokenizer/provider constructors, logits views,
guidance runtime types, and sampling protocol functions stay in private modules
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
