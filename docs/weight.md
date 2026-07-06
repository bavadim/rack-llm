# Weighted Observers

`weight` learns a single `Watch` from ranked text observers and unlabeled
calibration strings.

```racket
(weight #:data samples
        #:max-iter 50
        #:tol 1e-4
        (rank 1  (rx #px"https?://\\S+"))
        (rank -1 (rx #px"unknown|null")))
```

The implementation fits a two-class independent Bernoulli label model with EM.
Each ranked watcher becomes a binary feature. The sign of the original
`rank` orients the learned log-likelihood ratio:

```text
score += sign(rank) * abs(log P(feature|positive) / P(feature|negative))
```

Smoothing prevents zero probabilities. The resulting weighted observer stores
per-watcher learned weights and probabilities for trace/debug output.

Limitations:

- Data is unlabeled; without orientation signs, EM can flip latent classes.
- Watchers are treated as conditionally independent.
- No supervised calibration, anchors, or correlation model is included in v1.
