# T-066. Реализовать output artifacts для статьи

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 5 рабочих дней

### SMART goal

После запуска Weak-IFBench автоматически формировать таблицы CSV/Markdown для статьи: main results, calibration, cost, ablations.

### В скоупе

- `main_results.csv`.
- `calibration_metrics.csv`.
- `cost_metrics.csv`.
- `ablation_results.csv`.
- Markdown summary.

### Не в скоупе

- LaTeX table formatting.
- Plots.

### Публичные интерфейсы

CLI:

```bash
racket experiments/weak-ifbench/summarize.rkt runs/weak-ifbench --out tables/
```

### Unit tests

```racket
(check-true (csv-has-column? "main_results.csv" "GoldSuccess@8"))
(check-true (csv-has-column? "calibration_metrics.csv" "Brier"))
```

### Integration tests

- Fixture run produces all table files.

### Definition of Done (DoD)

- Tables generated from traces and gold files only.
- No manual spreadsheet edits required.

---
