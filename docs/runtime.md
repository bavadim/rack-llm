# Prefix Runtime

The runtime tracks whether a generated prefix is still viable, complete, or
dead.

```racket
(guide-init guide)       ; -> rt-state
(guide-step state token) ; -> rt-state
(guide-finish state)     ; -> rt-state
```

State predicates and accessors:

```racket
(dead? state)
(done? state)
(state-score state)
(state-potential state)
(state-value state)
(state-trace state)
```

`dead?` means the prefix cannot become a valid guide result. `done?` means the
prefix is already an accepted guide result. A prefix may be live but not done,
for example after token `"A"` in:

```racket
(seq "A" "B")
```

Generation uses the prefix runtime to test token viability for decoding instead
of treating `check(prefix)` failure as immediate death. Production sampling does
not call `check`, `parse-guide`, or unbounded `finite-candidates` inside the
token loop; unsupported guide kinds return `unsupported-guide-for-sampling`.

Finite closed guides can be enumerated with an explicit safety limit:

```racket
(finite-candidates (select "yes" "no"))
(finite-candidates guide #:max-finite-candidates 10000)
```

Open or infinite guides return `#f`; finite guides above the limit return
`'too-many`. Production sampling does not silently enumerate huge guides.

`fast-forward-state` advances deterministic literal fragments without using
provider logits for token choice. Generation uses this for fixed prefixes inside
larger guides, then asks the provider only when a non-deterministic choice is
needed.

`check` returns the same guide score and watcher trace model used by runtime
states. For hard guides, `ok?` means membership in the closed guide language.
For soft `text`, `ok?` is true unless a hard watcher such as `ban` rejects the
text.

## Complexity

Exact hard/open decoding with `#:candidate-policy 'full-vocab` is `O(TV)` for
`T` generated tokens and vocabulary size `V`.

Closed finite choices with `#:candidate-policy 'allowed-only` use provider-aware
tries and scan only the allowed next ids: `O(TA)`, where `A` is the number of
allowed children at the current trie node. If a runtime state cannot provide
allowed ids, the sampler falls back to full vocabulary.

Soft open text can use `#:candidate-policy '(top-k+watch K)`, where candidates
are top-K ids plus watched token ids from active watchers. The runtime scoring
pass is `O(T(K+W))`, with `W` watched ids. This mode is approximate: it does not
provide exact full-vocabulary guarantees or exact uniqueness without additional
memory.

`text #:until` is still supported by post-hoc `check`, but production sampling
returns `unsupported-guide-for-sampling` for it until a delimiter-aware
`text-until` runtime is implemented.
