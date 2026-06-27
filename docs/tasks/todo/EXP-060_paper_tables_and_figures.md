# EXP-060 — Сборка таблиц и графиков для статьи

## SMART goal

За 2 рабочих дня собрать из результатов notebook финальные таблицы и графики для IMRD-статьи.

## Notebook

`experiments/notebooks/060_paper_tables_and_figures.ipynb`

## Scope

Собрать результаты из:

- EXP-014 Weak-IFBench main experiment.
- EXP-020 Synthetic Gumbel correctness.
- EXP-021 Complexity microbenchmarks.
- EXP-030 JSONSchemaBench.
- EXP-040 BFCL.
- EXP-050 Patent case study, если есть.

Создать:

```text
experiments/results/paper/
  table_1_main_weak_ifbench.csv
  table_2_ablation.csv
  table_3_jsonschemabench.csv
  table_4_bfcl.csv
  table_5_complexity.csv
  figure_1_gold_success_vs_budget.png
  figure_2_selection_efficiency.png
  figure_3_complexity.png
  figure_4_calibration.png
```

## Out of scope

- Не пересчитывать эксперименты.
- Не менять значения вручную.
- Не рисовать «красивые» графики, которые не соответствуют CSV. Мы не маркетинг, даже если иногда хочется.

## Required paper tables

### Table 1 — Main Weak-IFBench

| Method | B=1 | B=4 | B=8 | B=16 | SelectionEfficiency@8 | DuplicateRate@8 |
|---|---:|---:|---:|---:|---:|---:|

### Table 2 — Ablation

| Configuration | GoldSuccess@8 | SelectionEfficiency@8 | Brier | ECE |
|---|---:|---:|---:|---:|

Rows:
- independent + majority
- independent + DS
- Gumbel + majority
- Gumbel + DS
- oracle verifier

### Table 3 — JSONSchemaBench

| Method | Coverage | Compliance | Compile ms | Generation ms |
|---|---:|---:|---:|---:|

### Table 4 — BFCL

| Method | AST Acc | Exec Acc | Invalid JSON | Hallucination |
|---|---:|---:|---:|---:|

### Table 5 — Complexity

| Component | Old | New | Speedup |
|---|---:|---:|---:|

## Unit tests

1. Notebook падает с понятной ошибкой, если нет нужного `summary.csv`.
2. Все таблицы имеют ожидаемые колонки.
3. Все графики создаются в `experiments/results/paper/`.

## Expected result

Готовый набор таблиц для статьи:
- main result;
- ablation;
- structured output;
- end-to-end function calling;
- complexity.

## DoD

- Все таблицы сохранены в CSV.
- Все графики сохранены в PNG и SVG.
- Есть `paper_results_manifest.json` со списком входных файлов и git commit.
