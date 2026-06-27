# Changelog

## v0.2-research

Research release target for the paper codebase.

### Added

- Provider v2 API with explicit provider mode, tokenizer, detokenizer, model
  state, logit vector result, and provider trace metadata.
- Deterministic mock provider for unit tests and small synthetic pipelines.
- Shared prompt rendering for compatibility providers and local runtimes.
- Gumbel stream core remains the constrained decoding baseline, now prepared to
  use an external agenda interface.
- Agenda interface with a sorted-list baseline for frontier-search ablations.
- Reproducibility metadata structure with JSON serialization and git commit
  capture helper.
- Documentation for Provider v2 and migration from legacy `TokenOracle`.

### Planned for the Research Release

- Rule API and rule combinators for post-generation acceptance.
- Dawid-Skene aggregation, including thresholded acceptance and diagnostics.
- Weak-IFBench fixture runner, baselines, calibration split, and paper tables.
- Local llama.cpp full-vocabulary provider.
- Heap agenda and complexity counters for paper-ready asymptotic reporting.

### Migration Notes

Legacy code can keep using `TokenOracle` with `eval`. New experiments should use
Provider v2 so provider mode, model identity, tokenization, state, and truncation
mass are traceable. Use `token-oracle->provider` only as a compatibility bridge;
it reports `compat-no-logits` by default and must not be used for exact
distribution tests.

### Known Limitations

- OpenAI Responses logprobs and HTTP top-logprob endpoints expose only a
  truncated distribution. They are useful for demos and weak baselines, but they
  cannot support exact Gumbel distribution claims.
- `truncated-top-k` runs must report discarded mass when it is available from a
  full-logits source; otherwise the truncation error is unknown.
- Dawid-Skene aggregation assumes conditionally independent weak rules given the
  latent label. Correlated rules need diagnostics and should be reported as a
  limitation in paper tables.
- The current local release foundation does not yet include the full
  Weak-IFBench runner or local full-vocabulary llama.cpp runtime.
