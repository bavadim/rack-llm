# Trace And Metrics

Trace entries are plain lists kept stable for debugging:

```text
(rank score expr)
(ban -inf.0 expr)
(weight learned-score expr (pos-prob p) (neg-prob q))
(check matched score)
(check mismatch -inf.0)
(final-value value)
```

`check-result` exposes:

```racket
check-result-trace
check-result-failures
check-result-matched-watchers
check-result-metrics
```

`generation-result` exposes:

```racket
generation-result-trace
generation-result-metrics
```

Metrics are raw library debug counters:

```text
steps
generated-tokens
llm-calls
dead-prefixes
rule-time-ms
llm-time-ms
provider-mode
attempts
latency-ms
```

These fields are not a benchmark results layer. Paper/experiment latency,
throughput, aggregation, confidence intervals, and plots are measured and
computed by scripts under `experiments/` through the public API. The library
does not include exporters, benchmark aggregation, or plotting.
