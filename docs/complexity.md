# Complexity

This document records the asymptotic complexity claims and the trace counters
used to produce complexity tables.

## Notation

- `N`: expanded frontier nodes.
- `E`: created candidate edges.
- `F`: maximum frontier size.
- `R`: rule observations evaluated for candidate acceptance.
- `C_LLM`: cost of one provider call.
- `C_G`: cost of one grammar/matcher check for a candidate edge.
- `C_H`: cost of one hard/soft rule evaluation.
- `I`: Dawid-Skene EM iterations.
- `M`: candidate-level observation sets used to fit Dawid-Skene.
- `H`: observed rule outputs per candidate-level observation set.
- `C_cache`: cached matcher, provider, and trace metadata.

The main decoding cost with the binary heap agenda is:

```text
T = O(N*C_LLM + E*C_G + (N+E)*log F + R*C_H)
Memory = O(F + C_cache)
```

Dawid-Skene fitting over `M` observation sets with `H` rule outputs per set and
`I` EM iterations is:

```text
T_DS = O(I*M*H)
```

Posterior prediction for one candidate is `O(H)`.

## Agenda

The sampler frontier size is `F`.

- `agenda-empty 'list` is the baseline ablation agenda. It keeps entries sorted
  on insertion, so `push` is `O(F)` and `pop-max` is `O(1)`.
- `agenda-empty 'binary-heap` is the default sampler agenda. It stores a max
  heap by priority with insertion-order tie breaking, so `push` is `O(log F)`
  and `pop-max` is `O(log F)`.
- `agenda-empty 'pairing-heap` is an optional functional pairing heap backend.
  It has amortized `O(1)` insertion and amortized `O(log F)` `pop-max`, while
  preserving the same priority and insertion-order tie semantics.

The heap does not claim constant-time `pop-max`; arbitrary floating priorities
require reheapifying after the root is removed.

## Gumbel Stream

The Gumbel stream repeatedly pops the best frontier node, asks the provider for
candidate continuations when the node can still expand, filters successors
through the grammar matcher, conditions child Gumbel scores, and pushes viable
children back onto the agenda.

- Provider work is represented by `N*C_LLM` because each expanded node can call
  the provider once.
- Grammar work is represented by `E*C_G` because each created child edge is
  checked by the matcher.
- Queue work is `(N+E)*log F` with the binary heap: each pop and each pushed
  viable edge costs logarithmic time in the frontier size.
- Rule work is `R*C_H` for acceptance filtering outside the stream.

The old sorted list agenda is still useful as an ablation, but it gives a
linear insertion cost. That changes queue work to `O(E*F + N)` in the worst
case. The binary heap is the release default because both push and pop are
`O(log F)`.

## Matcher

The public matcher interface is stateful at the grammar boundary:
`matcher-start` creates a state and `matcher-advance` consumes one provider
token string to produce the next state. The Gumbel stream calls
`matcher-advance` once per candidate edge and records that count as
`grammar_checks`. Provider and queue wall-clock time are tracked separately and
should not be attributed to `C_G`.

## Dawid-Skene

For binary latent quality, each EM iteration recomputes candidate posteriors and
then re-estimates rule confusion probabilities from the weighted observations.
With `M` candidate-level observation sets and `H` observed rule outputs per set,
the fit cost is:

```text
T_DS = O(I*M*H)
```

Per-constraint Dawid-Skene fits the same model independently for each
constraint with enough examples and uses one fallback model for sparse
constraints. The total cost is the sum of the same formula over fitted
constraint groups plus the fallback fit.

## Measured Counters

Complexity traces and tables use these column names:

- `expanded_nodes`: frontier nodes removed from the agenda and expanded.
- `created_edges`: candidate child edges created by provider continuations.
- `agenda_pushes`: agenda insertions, including the root node.
- `agenda_pops`: agenda removals.
- `max_frontier`: maximum agenda size observed during decoding.
- `provider_calls`: calls to the language-model provider.
- `grammar_checks`: matcher or grammar validity checks.
- `yielded_candidates`: completed candidates yielded by the stream.
- `queue_time_ms`: time spent in agenda operations.
- `provider_time_ms`: time spent waiting for provider results.
- `rules_time_ms`: time spent evaluating hard/soft rules.

`experiments/analyze-complexity.rkt` reads trace JSONL files containing those
fields and writes a CSV table grouped by `run_id`, `method`, and `budget`. Each
counter is emitted as `<counter>_mean` and `<counter>_std`.

`experiments/synthetic/gumbel-correctness.rkt` enumerates small finite
languages, compares top-1 Gumbel samples against the exact normalized
distribution, and reports `duplicate_rate`, `tv`, `kl`, and `order_agreement`.
The quick smoke target is:

```bash
make test-synthetic-small
```

The symbol-to-counter mapping is:

- `N`: `expanded_nodes`.
- `E`: `created_edges`.
- `F`: `max_frontier`.
- Agenda operations: `agenda_pushes` and `agenda_pops`.
- Accepted stream outputs: `yielded_candidates`.
- `R`: number of rule observations represented by `rules_time_ms` and future
  rule-count counters.
- `C_LLM`: measured through `provider_calls` and `provider_time_ms`.
- `C_G`: measured through `grammar_checks`.
- `C_H`: measured through `rules_time_ms`.

## Deduplication

`rack-llm/sampling/dedupe` provides local candidate deduplication filters:

- `tokens`: dedupe by token sequence.
- `string`: dedupe by final candidate string.
- `object`: dedupe by a caller-supplied normalized object key.

The filter returns `#t` for a new candidate and `#f` for a duplicate. Experiment
metrics record duplicate behavior through `duplicate-rate`; semantic equivalence
or embedding-based dedupe is intentionally out of scope.
