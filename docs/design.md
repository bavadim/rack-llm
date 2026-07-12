# Formal Design

Let `Q_T(x)` be the autoregressive model distribution including natural EOG or
the virtual horizon STOP, and let `H(x)` indicate acceptance by the hard
Program. A fitted weak model returns

```text
p(x) = P(z = good | lambda(x)).
```

For `tau` in `[0,1]`, exact PWSG generation targets

```text
pi_tau(x) = Q_T(x) H(x) p(x) 1[p(x) >= tau] / Z.
```

Hard-only generation is the special case with terminal mass one. Thresholding
changes support and posterior still reweights candidates above the threshold.

For rule `i`, `f_i = 1[lambda_i != 0]`. The label model contains `pi=P(z=1)`
and `theta_i,z=P(f_i=1 | z)`. EM evaluates responsibilities in log space,
applies Beta(2,2) smoothing, and projects every M-step onto
`theta_good >= theta_bad` for prefer and the reverse inequality for avoid.
Non-fire is informative; it is not treated as a negative label.

The fractional trie stores an envelope `h(x) >= m(x)`. On a terminal:

```text
m(x) = p(x), if p(x) >= tau; otherwise 0
accept probability = m(x) / h_old(x)
```

Only after the draw is `h(x)` replaced with `m(x)`. Consequently a stochastic
rejection does not remove the terminal, while a below-threshold terminal has
deterministic zero target mass. Each attempt's accepted density is proportional
to the same target even as the trie becomes tighter.
