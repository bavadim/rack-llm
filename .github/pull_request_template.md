## Checklist

- [ ] `make lint` passes.
- [ ] `make test` passes.
- [ ] `make test-integration` passes when integration behavior changed.
- [ ] Public API changes are documented.
- [ ] Trace or metadata changes preserve reproducibility.
- [ ] Randomized tests set an explicit deterministic seed.
- [ ] Provider mode is explicit: `exact-full-vocab`, `truncated-top-k`, or `compat-no-logits`.
- [ ] OpenAI or top-K providers are not used for exact distribution claims.
- [ ] IO remains at provider, trace, experiment, or script boundaries.
- [ ] Functional-core changes avoid hidden mutable state and global model/session state.

## Review Notes

- Describe the user-visible behavior change.
- Call out any paper-result, trace-schema, or migration impact.
- List any intentionally deferred todo task.
