# 014. Реализовать real runtime runners для hard методов

## SMART goal

Сделать реальные runtime runners для hard comparison: `ours_hard`, `guidance_hard`, `outlines_hard`. Результат задачи — pilot на 5 rows, где все методы реально генерируют текст через локальную Qwen модель.

## Зачем это нужно

Текущий hard benchmark проверяет grammar specs и regex witnesses, но не сравнивает runtime decoding. Для статьи нужно сравнение настоящих методов.

## Scope

Методы:

```text
ours_hard
guidance_hard
outlines_hard
```

Вход:

```text
data/hard_ifbench_subset.jsonl
data/hard_guide_build_report.jsonl
```

Создать runtime adapter layer в:

```text
experiments/012_real_model_benchmark/code/
```

## Out of scope

- Не использовать regex witnesses как benchmark output.
- Не запускать full hard benchmark.
- Не запускать soft benchmark.
- Не использовать official verifier во время generation.

## How

- `ours_hard`:
  - lower hard GuideSpec в Racket guide;
  - вызвать Racket `generate` через sidecar provider.
- `guidance_hard`:
  - lower hard GuideSpec в Guidance runtime constraint;
  - использовать ту же Qwen model/tokenizer.
- `outlines_hard`:
  - lower hard GuideSpec в Outlines runtime constraint;
  - использовать ту же Qwen model/tokenizer.
- Если constraint нельзя честно выразить в Guidance/Outlines runtime:

```text
UNSUPPORTED_CONSTRAINT
```

а не synthetic/witness output.

## Required outputs

```text
experiments/012_real_model_benchmark/results/014_hard_runtime_pilot_raw.jsonl
experiments/012_real_model_benchmark/results/014_hard_runtime_pilot_summary.csv
experiments/012_real_model_benchmark/results/014_hard_runtime_failures.jsonl
```

## Unit tests

- `test_hard_runtime_no_witness_mode`: runner не вызывает `candidate_from_spec` / witness path.
- `test_verifier_not_used_during_generation`: verifier импортируется только в evaluation step.
- `test_guidance_outlines_are_real_imports`: Guidance/Outlines импортируются и вызываются как runtime libraries.
- `test_unsupported_is_explicit`: unsupported rows имеют reason.

## DoD

- Pilot: 5 rows × 1 seed × 3 methods реально генерируются или явно unsupported.
- Raw rows содержат method, key, seed, text, latency, generated_tokens, outcome, failure_reason.
- Official verifier применяется только после generation.
- Нет synthetic/witness rows.
