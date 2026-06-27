# Dawid-Skene

`rack-llm/rules/dawid-skene` implements a binary latent-quality label model for
weak rule observations.

- Latent class `1` is the good candidate class.
- Latent class `0` is the bad candidate class.
- Outcomes are `accept`, `reject`, and `abstain`.
- EM estimates one confusion table per rule:
  `P(rule_outcome | latent_class)`.

The model uses log-space posterior prediction and additive smoothing. The
orientation problem is real: without anchors, an unsupervised DS model can swap
the good and bad classes. The implementation initializes `accept` as more likely
under class `1`, records orientation in model JSON, and exposes
`orient-ds-model` for manual, anchor-rule, and dev-gold orientation.

```racket
(require rack-llm/rules/acceptance
         rack-llm/rules/dawid-skene)

(define observations
  (list (list (rule-observation 'json-valid 'accept #f (hash))
              (rule-observation 'length-ok 'reject #f (hash)))))

(define model
  (fit-dawid-skene default-ds-config observations))

(ds-posterior model (first observations))
```

Models serialize with `ds-model->json` and load with `json->ds-model`.

## Rule Correlation Diagnostics

Dawid-Skene assumes that rules are conditionally independent given the latent
candidate quality. Weak heuristic rules often violate that assumption: two
rules may be near duplicates, or one rule may be a near deterministic inverse of
another. `rack-llm/rules/correlation` computes pairwise agreement and conflict
rates so the run can surface that risk.

```racket
(require rack-llm/rules/correlation)

(define report
  (analyze-rule-correlations observation-sets))

(rule-correlation-report-warnings report)
(rule-correlation-report->metrics report)
```

The metrics hash includes `high_correlation_pairs`, which should be written with
experiment metrics. The warnings are plain diagnostic strings and can be
appended to trace diagnostics.

## Orientation

`ds-orientation` records how class orientation was fixed:

- `manual`: `good-class` names the current latent class to treat as good. If it
  is `0`, the model is flipped so public `ds-posterior` still means probability
  of good.
- `anchor-rule`: a high-precision rule is expected to accept good candidates;
  the class with larger `P(anchor accepts | class)` becomes good.
- `dev-gold`: orientation is chosen on a development set of `gold-label`
  values. Test data should not be passed here.

## Per-Constraint Models

`constraint-observation` attaches a `constraint-id` to a `rule-observation`.
`fit-per-constraint-ds` trains one DS model per constraint id and also trains a
fallback model over all constraint observations.

Groups with fewer than two candidate-level observation sets use the fallback
model. `constraint-posteriors` returns a hash from constraint id to posterior,
which can be written directly into `candidate-trace` as
`constraint_posteriors`.

```racket
(define grouped
  (list (list (constraint-observation
               'word-count
               (rule-observation 'length-rule 'accept #f (hash))))))

(define pc-model
  (fit-per-constraint-ds default-ds-config grouped))

(constraint-posteriors pc-model (first grouped))
```
