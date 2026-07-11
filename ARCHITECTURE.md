# Architecture

The runtime is a small typed core around two native boundaries.

```text
main.rkt                 public DSL and generation loop
  private/model.rkt      tokenizer, session provider, model lifetime
  private/guidance.rkt   compiled programs and residual generation state
  private/sampling.rkt   exact full-vocabulary sampling
  private/cars.rkt       fractional-envelope prefix trie
  private/regex.rkt      typed PCRE2 facade
    private/pcre2-ffi.rkt
    native/regex/        PCRE2 DFA and token transition cache

model-llama-cpp.rkt
  native/llama/          in-process llama.cpp session provider
```

Model implementations construct one `Model`; the core never imports a model
backend. A provider exposes its EOG ids and one session protocol: start, read
current logits, commit a content token, and end.

Programs are immutable descriptions compiled against a tokenizer. Generation
then advances a residual guidance state. Hard regex constraints use restartable
PCRE2 DFA transitions for a conservative consuming subset and exact full-prefix
matching for boundary-sensitive constructs. Open `text` programs use
exact full-vocabulary logits with exact candidate vetoes and optional local
reward hints.

Regex programs compiled for one generator share one lazily created
native vocabulary. Token pieces cross the FFI boundary as one UTF-8 blob plus
lengths; native states retain the ownership chain `state -> regex -> vocabulary`.

`Program` never selects a sampler. A reusable generator owns the compiled
guidance, prompt ids, RNG and optional CARS trie. Local sampling follows one
masked path. CARS creates a fresh provider session per proposal and retains only
token-prefix probabilities and envelope masses between attempts and samples.

Forced deterministic segments do not query or replay the model. Consequently
their LM score is unknown (`#f`), while sampled segments retain exact log
probabilities. `#:max-tokens` and `#:deadline-ms` are the only runtime budgets.
The token budget is a stopping boundary, not a guarantee that every live regex
trajectory reaches an accepting state.
