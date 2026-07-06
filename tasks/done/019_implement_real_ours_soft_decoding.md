# 019. Реализовать real ours_soft_decoding через Racket generation

## SMART goal

Сделать `ours_soft_decoding` настоящим decoding-time методом, который вызывает Racket `generate` token-by-token с soft watchers, а не выбирает из готового candidate pool.

## Зачем это нужно

Главная идея библиотеки — controlled generation через формулу:

```text
total_score = lm_logprob + beta * guide_score
```

Если `ours_soft_decoding` работает posthoc, эксперимент не проверяет метод.

## Scope

Вход:

```text
data/012_soft_ifbench_rules_audited.jsonl
```

Noise levels:

```text
clean
noisy_20
noisy_40
```

Метод:

```text
ours_soft_decoding
ours_hybrid_decoding
```

## Out of scope

- Не использовать official verifier во время generation.
- Не использовать real candidate pool для выбора результата ours methods.
- Не менять watcher audit criteria.

## How

- Lower RuleSpec в Racket `text` watchers:
  - `kind=rank` -> `rank weight pattern`;
  - `kind=ban` -> `ban pattern`.
- Вызвать Racket `generate` с sidecar provider.
- Записать:
  - text;
  - lm_logprob;
  - guide_score;
  - total_score;
  - status;
  - trace;
  - latency;
  - generated tokens.

## Required outputs

```text
experiments/012_real_model_benchmark/results/019_ours_soft_smoke_raw.jsonl
```

## Unit tests

- `test_ours_soft_calls_racket_generate`
- `test_ours_soft_does_not_read_verifier_labels`
- `test_rank_changes_total_score`
- `test_ban_remains_hard_veto`
- `test_noise_level_rule_sets_load`

## DoD

- Smoke: 5 rows × 3 noise levels generate real texts.
- Raw smoke file has non-empty generated text or explicit generation failure.
- Verifier not used during generation.
- Racket path is exercised, not Python posthoc selection.
