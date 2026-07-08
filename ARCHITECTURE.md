# Architecture

The repository uses a small public facade over private token-native runtime
modules plus separate model implementations.

```text
main.rkt
  public Model type
  public filter builders
  public model-level generation entrypoint

private/logits.rkt
  logits view abstraction for vector and future foreign-backed logits

private/model.rkt
  tokenizer, provider, model runtime objects and session protocol

private/filter.rkt
  filter descriptions, states, watchers, and transition protocol

private/regex.rkt
  regex AST/parser, NFA compiler, token transition caches

private/sampling.rkt
  default token selection and logprob math

model-qwen.rkt
  Qwen sidecar model implementation
  returns one Model containing tokenizer + provider + close hook
```

`rack-llm` does not import model implementations. Model modules import the core
private runtime constructors and return `Model` values.

## Flow

```text
qwen-model -> Model
generate + Model + prompt text + FilterBuilder
private Tokenizer compiles FilterBuilder -> Filter
private Provider returns LogitsView
private sampler produces token ids
public result contains generated text
```

## State

Tokenizer/provider state, logits views, filter state, and filter protocol
functions are internal. Users construct a filter builder and pass it with a
model and prompt string to `generate`. Public results expose generated text,
token ids, scores, metrics, status, reason, and trace.

## Regex

`rx` compiles regex source with a tokenizer into a token-level automaton. The
sampling hot path uses `state + token-id -> next-state`; it does not call string
regexp matching per candidate.

## Known Repair Tracks

Exact full-vocabulary soft decoding is the main open runtime repair. The
current implementation is exact but can be too slow for Qwen-scale open text
watchers; benchmark artifacts based on top-k approximations must not be treated
as paper-grade exact evidence.

Experiment runners under `experiments/` are outside the core library boundary
and may lag behind the public API. They must be realigned before regenerating
`012_*` artifacts.
