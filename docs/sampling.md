# Sampling Math

Provider callbacks return logits: unnormalized model scores.

Candidate comparison uses log-probabilities:

```text
lm_logprob(y) = sum_t log p(y_t | prompt, y_<t)
total = lm_logprob + beta * guide_score
```

`log-softmax` converts logits into log-probabilities:

```racket
(log-softmax '#(0.0 0.0)) ; => #(-0.693... -0.693...)
```

`sequence-logprob` tokenizes text with the provider vocabulary and sums token
log-probabilities across positions.

`generate` samples each token from adjusted logits:

```text
adjusted(v) = logit(v) + guide_adjustment(v)

guide_adjustment(v) =
  -inf                                      if the guide transition is dead
  beta * (Delta score + lambda * Delta potential) otherwise
```

Hard-dead tokens are masked to `-inf.0` independently of `beta`.

Candidate policies control which token ids receive runtime scoring:

| Policy | Candidate set | Guarantee |
|---|---|---|
| `'full-vocab` | every provider token id | exact full-vocabulary masking/scoring, `O(TV)` |
| `'allowed-only` | current runtime `allowed-next-ids`, or full-vocab fallback | exact for finite trie states, `O(TA)` when available |
| `'(top-k+watch K)` | top-K logits plus watched token ids | approximate soft mode, runtime pass `O(T(K+W))` |

`top-k+watch` is intentionally approximate. It is useful for soft `text`
watchers when full-vocabulary scoring is too expensive, but it cannot guarantee
that every high adjusted-score token outside `TopK union WatchIds` was examined.

The implementation uses a streaming Gumbel-Max pass over the selected candidate
ids rather than materializing all adjusted logits. If `#:deadline-ms` expires
during this pass, `generate` returns `error-budget` instead of continuing past
the budget.

`sample-id` implements seed-controlled Gumbel-Max sampling over adjusted logits:

```racket
(sample-id adjusted-logits rng temperature)
```

Temperature must be positive. Tokens with `-inf.0` logits are unsampleable.

`generate` accepts `#:beta`, `#:lambda`, `#:temperature`, `#:seed`,
`#:deadline-ms`, and `#:max-tokens`.

`generate-stream` returns a lazy stream of candidates. `generate` consumes that
stream with `#:samples`; with `#:keep-best? #t`, it returns the candidate with
maximum `total-score`. `#:unique 'none` allows repeated text. `#:unique '(cache
N)` skips exact text repeats seen in the last `N` accepted candidates.

`#:return-policy` controls soft abstention after candidates are produced:
`'always`, `'hard-only`, `(min-guide-score threshold)`, or `(min-total-score
threshold)`.

Metrics in `generation-result-metrics` include `vocab-size`,
`candidate-count-total`, `candidate-count-per-step`, `provider-calls`,
`llm-time-ms`, `rule-time-ms`, `sampling-time-ms`, `runtime-step-calls`,
`check-calls-in-sampling`, `parse-guide-calls-in-sampling`, `regex-calls`,
`dead-token-count`, `allowed-token-count`, `fast-forward-tokens`,
`candidate-policy`, and `provider-session?`.

The hot path reports `check-calls-in-sampling = 0` and
`parse-guide-calls-in-sampling = 0`; post-hoc `check` remains available as a
separate validator.

Weighted observers are documented in `docs/weight.md`.
