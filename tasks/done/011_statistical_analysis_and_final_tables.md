# 011. Посчитать статистическую значимость и собрать финальные таблицы

Status: done

## Reopen note

Предыдущие финальные таблицы/статтесты считаются pilot/non-paper-grade и не
должны использоваться как evidence. Задача переоткрыта, чтобы анализ
пересчитывался только из обновленных experiment artifacts и fail-closed
реагировал на missing rows или неполные методы.

## SMART goal

На основе результатов задач 005, 006 и 010 построить финальные таблицы, доверительные интервалы и статистические тесты. Завершить за 2 рабочих дня после задачи 010.

## Зачем это нужно

Нужно отделить “график выглядит лучше” от “результат устойчив”. Да, это разные вещи, хотя многие статьи об этом забывают и потом очень уверенно машут шумом.

## Scope

Входы:

```text
results/005_hard_solve_raw.jsonl
results/006_hard_convergence_raw.jsonl
results/010_soft_noisy_raw.jsonl
```

Сделать:

- paired bootstrap CI по prompt id;
- McNemar tests для парных бинарных исходов;
- Wilcoxon signed-rank для latency/tokens;
- Holm-Bonferroni correction для основных сравнений;
- финальные CSV и PNG figures.

## Out of scope

- Не запускать генерацию.
- Не менять rules.
- Не менять dataset splits.

## Main comparisons

### Hard non-inferiority

Compare:

```text
ours_hard vs guidance_hard
ours_hard vs outlines_hard
```

Criteria:

```text
SolveRate difference CI lower bound >= -0.02
median latency ratio CI upper bound <= 1.25
WrongRate <= 0.01
```

### Soft noisy superiority

Compare:

```text
ours_soft_decoding vs weak_posthoc_rerank
ours_soft_decoding vs weak_rejection
ours_hybrid_decoding vs weak_posthoc_rerank
ours_hybrid_decoding vs best_of_n_lm
```

Main metric:

```text
SafeSolve@5%
```

Success criterion:

```text
improvement >= +5 percentage points
95% bootstrap CI excludes 0
p < 0.05 after Holm-Bonferroni
```

## Required outputs

```text
results/011_hard_final_table.csv
results/011_soft_final_table.csv
results/011_stat_tests.csv
figures/011_hard_solve_vs_time.png
figures/011_soft_risk_coverage.png
figures/011_noise_robustness.png
figures/011_first_gold_rank.png
```

## Statistical procedure

- Bootstrap resampling unit: `example_id`, not candidate.
- Use 10,000 bootstrap resamples.
- For McNemar, compare paired outcomes on the same example ids.
- For latency, compute paired median difference and Wilcoxon test.
- If method failed on row, keep row as `NOT_FOUND`, do not silently drop it.

## Unit tests

- `test_bootstrap_resamples_by_example`: bootstrap samples example ids, not candidates.
- `test_missing_rows_not_dropped`: if a method lacks row, report error, do not compute table silently.
- `test_oracle_not_in_main_comparison`: oracle appears only as upper bound.

## DoD

- Final CSV and figures created.
- Statistical tests include adjusted p-values.
- Main claims are marked as `supported`, `not_supported`, or `inconclusive`.
- A short `results/011_claims.md` file states:
  - hard non-inferiority result;
  - soft noisy rules result;
  - robustness under 20% and 40% noise;
  - cost-quality tradeoff.

## Result

Пересчитано из обновленных 005/006/010 artifacts с 10 000 bootstrap resamples.
Hard non-inferiority: `inconclusive` из-за latency ratio (`ours_hard` медленнее
Guidance/Outlines на paired FOUND_OK rows) и низкого full-subset runtime
coverage. Soft superiority: `inconclusive` в целом; `ours_*` supported против
weak rule baselines на noisy_40/N=16, но не превосходит `best_of_n_lm`.
