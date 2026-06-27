# Thresholded Acceptance

`rack-llm/rules/threshold-acceptance` combines hard-rule reports with
per-constraint DS posteriors.

`accept-candidate` is deterministic and returns an `acceptance-decision`:

- `accepted?`: final candidate-level decision.
- `hard-passed?`: copied from the hard-rule report.
- `score`: minimum posterior for `all-constraints` and `min-posterior`, or a
  weighted average for `weighted-sum`.
- `constraint-posteriors`: the traceable posterior vector.
- `diagnostics`: hard-rule diagnostics plus threshold rejection reasons.

Modes:

- `all-constraints`: every `eta_c` must pass that constraint's threshold, or the
  default threshold if no per-constraint threshold exists.
- `weighted-sum`: weighted average of posteriors must pass the default
  threshold.
- `min-posterior`: minimum posterior must pass the default threshold.

```racket
(require rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene
         rack-llm/rules/threshold-acceptance)

(define cfg
  (acceptance-config 'all-constraints
                     0.7
                     (hash 'word-count 0.8)
                     (hash)))

(accept-candidate cfg hard-report per-constraint-model constraint-observations)
```

If a caller already has posterior-like scores, use `accept-posteriors` with the
same config and hard-rule report.

## Same-Stream Resampling

`rack-llm/resampling` consumes any candidate sequence and applies an acceptance
decision function until the first candidate is accepted or a budget is
exhausted.

```racket
(require rack-llm/resampling)

(resample-until-accepted
 (resampling-config 16 1000 60000 'return-fail)
 candidate-stream
 decide-candidate)
```

This is same-stream resampling: rejected candidates do not modify the prompt and
do not trigger another provider call outside the supplied stream. Repair prompts
are a separate mode because they create a new stream and a different
distribution.

## Repair Prompt Mode

`rack-llm/repair` provides the separate repair-prompt helper:

```racket
(require rack-llm/repair)

(make-repair-transcript transcript rejected-candidate acceptance-decision)
```

The helper appends a short user message with the rejected candidate and rule
diagnostics. The caller must start a new generation stream for that transcript
and record a new stream id in traces; it is not a continuation of the original
without-replacement stream.

## Aggregation Baselines

`rack-llm/rules/aggregation-baselines` provides simple weak-rule aggregation
baselines for comparison with Dawid-Skene:

- `majority-posterior-like`: returns `1.0` for an accept majority, `0.0` for a
  reject majority, and `0.5` for ties or only abstentions.
- `equal-weight-score`: returns `accept / (accept + reject)` and ignores
  abstentions. If there are no accept/reject observations it returns `0.5`.

These scores are in `[0, 1]` so they can pass through the same threshold
acceptance code, but they are not calibrated posteriors.

```racket
(require rack-llm/rules/aggregation-baselines
         rack-llm/rules/threshold-acceptance)

(define posteriors
  (baseline-constraint-posteriors 'equal-weight constraint-observations))

(accept-posteriors cfg hard-report posteriors)
```
