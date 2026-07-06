# 017. Сгенерировать real soft candidate pool

## SMART goal

Сгенерировать real vanilla candidate pool на Qwen3.5 для всех soft-supported rows после расширения coverage. Минимум: `soft rows × 16 candidates × 5 seeds`.

## Зачем это нужно

Synthetic candidate pool делает soft results непригодными для статьи. Нужны реальные model samples, на которых weak watchers могут быть честно audited и сравнены.

## Scope

Вход:

```text
data/soft_ifbench_rules.jsonl
```

Генерация:

```text
16 candidates per row
5 seeds
temperature 0.7
top_p 0.95
max_tokens 128
```

## Out of scope

- Не запускать soft-guided decoding.
- Не rerank candidates.
- Не фильтровать candidates по weak score.

## How

- Использовать sidecar op `generate_unconstrained`.
- Для каждого candidate сохранить:
  - row key;
  - candidate id;
  - seed;
  - text;
  - token ids;
  - token logprobs;
  - total lm logprob;
  - latency;
  - generated tokens;
  - finish reason;
  - official verifier result.

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_soft_candidate_pool.jsonl
data/012_soft_candidate_pool.jsonl
```

## Unit tests

- `test_candidate_pool_has_no_synthetic_source`
- `test_each_row_has_required_candidate_count`
- `test_candidate_pool_has_verifier_labels`
- `test_candidate_metadata_has_model_and_seed`

## DoD

- Candidate pool created from real Qwen generation.
- No `synthetic_offline` source rows.
- Every candidate has official verifier label.
- Missing/failed generations are recorded with explicit reason.
