# Generation Status

`GenerationResult` uses explicit status fields instead of a bare success
boolean.

## Statuses

| Status | Meaning |
|---|---|
| `found` | A candidate was produced and passes the guide. |
| `not-found-hard` | Hard structure or a hard veto made all available candidates invalid. |
| `not-found-budget` | The token budget ended before a complete valid result was found. |
| `not-found-low-score` | A return policy rejected the best result for low guide score. |
| `error-budget` | The wall-clock deadline expired during exact generation work. |
| `error-approx-provider` | A provider cannot support the requested exact operation. |
| `internal-invalid` | The runtime reached an inconsistent state. |
| `unsupported-guide-for-sampling` | The guide can be checked post-hoc but has no production prefix-runtime for sampling. |

## Predicates

```racket
(found? result)
(not-found? result)
(hard-failure? result)
(low-score? result)
(provider-error? result)
(generation-result-ok? result)
```

`generation-result-ok?` is a compatibility helper derived from status. It is
true only when `status` is `found`.

## Fields

```racket
(struct generation-result
  (status reason text value lm-logprob guide-score total-score
          hard-ok? low-score? steps attempts generated-tokens latency-ms
          trace metrics)
  #:transparent)
```

`reason` should be `#f` for `found` and a short human-readable explanation for
non-found statuses.

## Return Policy

Return policy is applied after generation, outside the DSL:

```racket
'always
'hard-only
(min-guide-score threshold)
(min-total-score threshold)
```

Hard failures and budget failures keep their original status. Low-score
abstention only rewrites otherwise `found` results to `not-found-low-score`.
