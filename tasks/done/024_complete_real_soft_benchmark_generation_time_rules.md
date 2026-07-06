# 024. Доделать soft benchmark: real soft rules в generation-time decoding

## SMART goal

Доделать soft benchmark так, чтобы `ours_soft_decoding` и `ours_hybrid_decoding` реально вызывали Racket generation с audited soft rules, а не отсутствовали из full benchmark и не подменялись posthoc candidate-pool selection.

## Зачем это нужно

Текущий `012_soft_real_*` benchmark не доказывает soft method: `weak_posthoc_rerank` и `weak_rejection` используют audited soft rules на candidate pool, но `ours_soft_decoding` / `ours_hybrid_decoding` отсутствуют и записаны как `48` missing combinations. Нужно измерить настоящий generation-time метод:

```text
total_score = lm_logprob + beta * guide_score
```

## Scope

Вход:

```text
data/012_soft_ifbench_rules_audited.jsonl
```

Методы:

```text
ours_soft_decoding
ours_hybrid_decoding
```

Noise:

```text
clean
noisy_20
noisy_40
```

Budgets:

```text
N = 1, 4, 8, 16
```

Return policies:

```text
always
risk_target:0.05
```

## Out of scope

- Не использовать official verifier во время generation/selection.
- Не подменять `ours_*` posthoc rerank по `data/012_soft_candidate_pool.jsonl`.
- Не менять audit criteria и не снижать порог audited rows.
- Не сравнивать Guidance/Outlines в soft mode.

## How

- Lower audited `RuleSpec` в Racket watchers:
  - `kind=rank` -> `rank weight pattern`
  - `kind=ban` -> `ban pattern`
- `ours_soft_decoding` и `ours_hybrid_decoding` должны вызывать Racket `generate`.
- Raw output для `ours_*` должен содержать:
  - `text`
  - `lm_logprob`
  - `guide_score`
  - `total_score`
  - `status`
  - `latency_ms`
  - `generated_tokens`
  - `trace`
  - `rule_set_hash`
  - `uses_candidate_pool=false`
  - `uses_official_verifier_for_selection=false`
- Решить performance bottleneck open-text decoding:
  - текущий full-vocab x regex-watchers path слишком медленный;
  - minimum v1 acceptable path: top-k token shortlist from model logits, then watcher scoring only over shortlisted tokens;
  - raw rows must record `provider_mode` / `approximation`, so approximate top-k is not presented as exact full-vocab decoding.

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_soft_real_raw.jsonl
experiments/012_real_model_benchmark/results/012_soft_real_summary.csv
experiments/012_real_model_benchmark/results/012_soft_real_risk_coverage.csv
experiments/012_real_model_benchmark/results/012_missing_runs.json
data/012_soft_real_raw.jsonl
data/012_soft_real_summary.csv
data/012_soft_real_risk_coverage.csv
data/012_missing_runs.json
data/012_soft_final_table.csv
data/012_stat_tests.csv
data/012_claims.md
```

## Unit tests

- `test_ours_soft_rules_are_loaded_from_audited_jsonl`
- `test_ours_soft_generation_not_candidate_pool`
- `test_ours_soft_has_no_missing_combinations`
- `test_ours_soft_has_real_generation_fields`
- `test_oracle_not_used_by_ours_soft`
- `test_soft_rules_affect_decoding_score`
- `test_soft_summary_includes_ours_methods`

## DoD

- `012_missing_runs.json` is empty, or contains only documented infrastructure failures unrelated to `ours_*` coverage.
- `012_soft_real_raw.jsonl` contains rows for:

```text
ours_soft_decoding
ours_hybrid_decoding
```

for all `3 noise levels x 4 budgets x 2 policies x audited rows`.

- `ours_*` rows use audited soft rules during generation, not posthoc candidate-pool selection.
- At least one non-timeout generated text exists for every audited row/noise pair in smoke/full run, or the row is explicitly classified as unsupported with reason.
- `SafeSolve@5%`, `FoundOK`, `FoundWrong`, coverage, latency, and generated tokens are reported for `ours_*`.
- Soft claims are recomputed from updated `012_*` artifacts; claim status is no longer `inconclusive` due to missing generation-time runs.
- `test_real_model_benchmark.py`, new soft runtime tests, and `make ci` pass.
