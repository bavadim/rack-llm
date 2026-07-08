# Architecture

The repository uses one typed token-native core module plus separate model
implementations.

```text
main.rkt
  Tokenizer, Provider, Model interface objects
  filter constructors and filter protocol
  token-level regex engine
  generation loop over token ids

model-qwen.rkt
  Qwen sidecar model implementation
  returns one Model containing tokenizer + provider + close hook
```

`rack-llm` does not import model implementations. Model modules import the core
interface and construct `Model` values.

## Flow

```text
qwen-model -> Model
model-tokenizer/model-provider -> Tokenizer + Provider
DSL constructors + Tokenizer -> Filter
Provider + prompt ids + Filter -> generation-result
detokenize -> text at the edge
```

## State

Filter state is internal to the core. Users can inspect it only through the
filter protocol functions:

```racket
filter-initial
filter-step
filter-allowed-ids
filter-accepting?
filter-terminal?
filter-dead?
filter-score
filter-potential
filter-value
filter-token-ids
filter-trace
```

## Regex

`rx` compiles regex source with a tokenizer into a token-level automaton. The
sampling hot path uses `state + token-id -> next-state`; it does not call string
regexp matching per candidate.
