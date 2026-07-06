# 015. Запустить полный real hard benchmark

## SMART goal

Запустить paper-grade hard benchmark на локальной Qwen3.5 модели для всех hard rows, поддержанных всеми runtime methods. Завершить после задачи 014.

## Зачем это нужно

Hard часть должна доказать, что наш runtime constrained decoding не хуже Guidance/Outlines на реальной модели, а не только строит эквивалентные specs.

## Scope

Методы:

```text
ours_hard
guidance_hard
outlines_hard
```

Seeds:

```text
0 1 2 3 4
```

Вход:

```text
data/hard_ifbench_subset.jsonl
```

## Out of scope

- Не запускать soft benchmark.
- Не строить финальные statistical claims.
- Не включать rows, unsupported одним из runtime methods, в paired comparison.

## How

- Использовать runners из задачи 014.
- Для каждого row/method/seed:
  - сгенерировать text;
  - посчитать official IFBench verifier;
  - записать latency, generated tokens, attempts/status.
- Unsupported rows записывать отдельно и исключать из paired hard comparison.

## Required outputs

```text
experiments/012_real_model_benchmark/results/012_hard_real_raw.jsonl
experiments/012_real_model_benchmark/results/012_hard_real_summary.csv
experiments/012_real_model_benchmark/results/012_hard_runtime_failures.jsonl
data/012_hard_real_raw.jsonl
data/012_hard_real_summary.csv
data/012_hard_runtime_failures.jsonl
```

## Metrics

- SolveRate
- WrongRate
- NotFound/Unsupported rate
- median latency
- p95 latency
- generated tokens
- attempts

## Unit tests

- `test_all_paired_supported_rows_have_all_methods`
- `test_hard_raw_has_no_synthetic_source`
- `test_hard_summary_matches_raw_counts`
- `test_official_verifier_column_present`

## DoD

- Full hard raw and summary files created.
- Every missing/unsupported run has explicit reason.
- Paired comparison subset is reproducible.
- No witness/spec-only outputs appear in raw results.
