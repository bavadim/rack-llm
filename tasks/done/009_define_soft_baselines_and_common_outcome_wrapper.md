# 009. Реализовать common wrapper для soft baselines и трех исходов

## SMART goal

Реализовать общий wrapper, который превращает candidate stream любого метода в один из трех исходов: `FOUND_OK`, `FOUND_WRONG`, `NOT_FOUND`. Реализовать soft baselines. Завершить за 2 рабочих дня после задачи 008.

## Зачем это нужно

Для soft noisy rules нельзя просто считать accuracy. Метод может честно отказаться, если score низкий. В продукте `NOT_FOUND` часто лучше, чем `FOUND_WRONG`. Да, впервые “ничего не сделать” является функциональной возможностью, а не багом менеджмента.

## Scope

Создать:

```text
experiments/ifbench/soft_methods.py
experiments/ifbench/outcomes.py
```

Методы:

```text
vanilla
best_of_n_lm
weak_posthoc_rerank
weak_rejection
ours_soft_decoding
ours_hybrid_decoding
oracle_verifier_selection
```

## Out of scope

- Не запускать полный benchmark.
- Не делать статистику.
- Не строить watchers.

## Outcome wrapper

```python
classify(candidate_or_none, official_verifier) -> Outcome
```

Семантика:

```text
if no candidate returned: NOT_FOUND
elif official_verifier(candidate.text): FOUND_OK
else: FOUND_WRONG
```

## Return policy for soft methods

Soft methods must support:

```text
return_policy='always'
return_policy=('min_score', tau)
return_policy=('risk_target', epsilon, dev_scores)
```

For `risk_target`, choose threshold on dev set so that:

```text
FoundWrong <= epsilon
```

Use epsilon values:

```text
0.01, 0.05, 0.10
```

## Baseline semantics

### `vanilla`

One standard sample, no weak score. Always returns candidate unless generation fails.

### `best_of_n_lm`

Generate N vanilla candidates; return candidate with highest LLM logprob.

### `weak_posthoc_rerank`

Generate N vanilla candidates; compute weak score with DSL check; return max weak score if passes return policy.

### `weak_rejection`

Generate N vanilla candidates; return first candidate with weak score ≥ threshold; otherwise NOT_FOUND.

### `ours_soft_decoding`

Use library decoding-time `rank`/`ban` in `text` with audited soft rules. Return best candidate by internal score and return policy.

### `ours_hybrid_decoding`

Use hard skeleton where available plus soft watchers. If no hard skeleton exists, fall back to `ours_soft_decoding` and mark `hybrid_fallback=true`.

### `oracle_verifier_selection`

Generate N candidates; return first or best candidate that official verifier accepts. This is upper bound, not a real method.

## Required output schema per candidate

```json
{
  "example_id": "...",
  "method": "weak_posthoc_rerank",
  "candidate_id": 3,
  "text": "...",
  "lm_logprob": -123.4,
  "weak_score": 4.0,
  "total_score": -119.4,
  "returned": true,
  "return_policy": "min_score:3.0"
}
```

## Unit tests

- `test_found_ok`: accepted text maps to `FOUND_OK`.
- `test_found_wrong`: rejected text maps to `FOUND_WRONG`.
- `test_not_found`: no candidate maps to `NOT_FOUND`.
- `test_weak_rejection_threshold`: returns NOT_FOUND when all scores below threshold.
- `test_oracle_not_used_by_real_methods`: only `oracle_verifier_selection` may call official verifier during selection.

## DoD

- All soft methods implemented.
- Common outcome wrapper implemented.
- Unit tests pass.
- Code has a guard preventing official verifier use inside real methods.
