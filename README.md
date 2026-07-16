# rack-llm

`rack-llm` is a token-native Racket library for exact hard-constrained and
programmatic weak sequence generation. The runtime combines an immutable
program, a stateful model session and CARS rejection sampling.

```racket
(require rack-llm
         rack-llm/model-llama-cpp)

(define spec
  (control
   (text 64)
   (prefer (ere "US[0-9]+"))
   (prefer (ere "[0-9]+%"))
   (avoid  (ere "TODO|unknown"))
   (ban    (lit "private key"))))
(define compiled (compile-spec model spec))

(define observations
  (for/list ([candidate calibration-corpus])
    (observe compiled candidate)))
(define weak-model (fit-weak-model observations))

(define generator
  (make-generator
   compiled prompt
   #:sampler (cars-sampler #:max-attempts 100
                           #:weak-model weak-model)
   #:temperature 0.7
   #:max-tokens 64
   #:seed 0))
(define result (generator-sample! generator))
(generator-close! generator)
(compiled-spec-close! compiled)
```

## Programs

- `lit` is an exact token sequence.
- `rx` is the extended PCRE2 hard-regex API.
- `ere` is the portable case-sensitive Unicode profile used by PWSG.
- `seq`, `choice`, and bounded `repeat` compose programs.
- `text` is an open `0..n` token fragment and must be in tail position.
- `control` scopes `prefer`, `avoid`, and hard `ban` rules.

`prefer` emits `+1` on a match and `0` otherwise. `avoid` emits `-1` on a
match and `0` otherwise. Non-fire is an observed abstention in the weak model.
`ban` changes the hard language and never appears in the weak label vector.
Abstain is not the opposite vote, although its calibrated frequency can still
be informative in the generative model.

The ERE profile supports literals, `.`, alternation, groups, character classes,
`* + ? {m} {m,n} {m,}`, `^`, `$`, and escaped metacharacters/newlines. It does
not support flags, shorthand character classes, lookaround, backreferences, or
other PCRE extensions. A guide uses fullmatch semantics; a control rule uses
search semantics relative to its scope.

## Weak model

`fit-weak-model` fits a constrained two-component product-Bernoulli model with
EM. Each rule learns `P(fire | bad)` and `P(fire | good)`; polarity constraints
orient the latent classes. Fits with fewer than three informative non-duplicate
rules, non-convergence, or collapse fail closed under a conditional-independence
model. Diagnostics report coverage, pairwise agreement/Jaccard/phi correlation,
high-correlation warnings, and effective rank.

Models and observations carry structural SHA-256 fingerprints. Structural
schemas intentionally exclude concrete pattern strings so one model can be fit
across specifications produced by the same parameterized builder. Full spec
fingerprints retain the concrete patterns. Models can be saved and loaded as
versioned JSON.

`compile-spec` builds the regex vocabulary and hard/weak runtimes once.
`observe-many` therefore scales with candidate tokens rather than vocabulary
size. String observation is strict; datasets may use `observe-token-ids`.

## Exact sampling

With posterior `p(x)` and threshold `tau`, PWSG CARS samples

```text
pi(x) proportional to Q_temperature(x) H(x) p(x) 1[p(x) >= tau].
```

The default threshold is zero. Hard-only CARS uses terminal mass one. The
fractional envelope trie is reused across calls to one generator; random weak
rejections update a terminal to its posterior mass, never to zero. Temperature
affects only the model distribution. There are no manual scores, beta, local
potentials, top-k approximation, or fallback result.

`#:sampler` and its attempt budget are required. Deadline checks occur between
complete attempts, so one attempt may overrun a deadline without censoring a
candidate midway.

## Layout

```text
main.rkt                 public DSL, observations and exact generator
private/guidance.rkt     Program AST and token-native residual states
private/weak.rkt         observations, EM and model persistence
private/weak-json.rkt    untyped JSON file boundary
private/cars.rkt         reusable fractional envelope trie
private/domain.rkt       compact all/only/except token domains
private/regex.rkt        ERE parser and PCRE2 runtime facade
private/model.rkt        tokenizer, provider sessions and model lifetime
model-llama-cpp.rkt      native stateful llama.cpp model and CARS scan
```
