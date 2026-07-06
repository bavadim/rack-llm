# 023. Починить hard benchmark: repeat_span и нулевой WrongRate/ErrorRate у Outlines

## SMART goal

Починить hard benchmark так, чтобы `repeat:repeat_span` lowering соответствовал IFBench word-index semantics, а `outlines_hard` в paired supported subset не имел `WRONG` или `ERROR` outcomes.

## Зачем это нужно

Текущий `012_hard_real_summary.csv` показывает `outlines_hard wrong_rate=0.0909`. Все ошибки приходятся на `key=285`, где `repeat:repeat_span` был скомпилирован как character slice (`" a descript"`) вместо inclusive word-index span. Это делает сравнение с Outlines некорректным: hard runtime должен сравниваться на корректно lowered constraints.

## Scope

- Исправить `repeat:repeat_span` hard guide builder.
- Пересобрать hard guide report.
- Перезапустить hard benchmark для методов:
  - `ours_hard`
  - `guidance_hard`
  - `outlines_hard`
- Пересчитать hard final tables/stat tests/claims и reproducibility hashes.

## Out of scope

- Не менять soft benchmark.
- Не удалять `key=285` или другие строки ради улучшения метрик.
- Не подменять runtime outputs witness/spec-only результатами.

## How

- В `experiments/003_hard_guides/code/hard_guides.py` трактовать `n_start`/`n_end` как inclusive word indices:
  - `words = prompt_to_repeat.split()`
  - validate `0 <= n_start <= n_end < len(words)`
  - `choice = " ".join(words[n_start:n_end + 1])`
- Для `key=285` expected choice должен быть:

```text
screenplay of a fish being pulled out of the water by
```

- Усилить runtime validation для finite-choice hard methods:
  - output должен быть exactly one of `spec.choices` before official verifier;
  - prefix/truncated text должен становиться explicit failure, а не обычным generated answer.

## Required outputs

```text
data/hard_guide_build_report.jsonl
data/012_hard_real_raw.jsonl
data/012_hard_real_summary.csv
data/012_hard_runtime_failures.jsonl
data/012_hard_final_table.csv
data/012_stat_tests.csv
data/012_claims.md
experiments/012_real_model_benchmark/results/012_hard_real_raw.jsonl
experiments/012_real_model_benchmark/results/012_hard_real_summary.csv
experiments/012_real_model_benchmark/results/012_hard_runtime_failures.jsonl
```

## Unit tests

- Update `repeat:repeat_span` test so:
  - `prompt_to_repeat="zero one two three four", n_start=1, n_end=3`
  - valid: `"one two three"`
  - invalid: `"ero"`, `"one two"`, `""`
- Add regression test for `key=285` or an equivalent long prompt.
- Add benchmark test that `outlines_hard` has no `WRONG`/`ERROR` rows in `012_hard_real_raw.jsonl`.

## DoD

- `repeat:repeat_span` is implemented with inclusive word indices.
- `key=285` no longer emits `" a descript"` / `" a descri"` in hard artifacts.
- `outlines_hard` in `012_hard_real_summary.csv` has:

```text
solve_rate=1.0
wrong_rate=0.0
error_rate=0.0
```

- Paired hard subset is not reduced artificially.
- Every unsupported/missing run has explicit reason in failures artifact.
- `012` claims/stat tests are recomputed only from updated `012_*` artifacts.
- `make ci`, hard guide tests, and 012 tests pass.
