# T-063. Реализовать calibration/dev/test split runner

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить runner, который разделяет данные на calibration/dev/test, обучает Dawid–Skene на calibration без gold, выбирает thresholds/orientation на dev, и один раз оценивает на test.

### В скоупе

- Split by task id with seed.
- Calibration candidate generation.
- DS fit.
- Threshold tuning on dev.
- Final test evaluation.

### Не в скоупе

- Cross-validation.
- Hyperparameter sweeps beyond thresholds.
- Human evaluation.

### Публичные интерфейсы

CLI:

```bash
racket experiments/weak-ifbench/runner.rkt \
  --data weak-ifbench.jsonl \
  --provider llama-local \
  --model model.gguf \
  --budgets 1,2,4,8,16 \
  --seed 42 \
  --out runs/weak-ifbench
```

Internal:

```racket
(struct experiment-split ([calibration : (Listof String)] [dev : (Listof String)] [test : (Listof String)]) #:transparent)
(: make-split (-> (Listof ifbench-task) Integer experiment-split))
```

### Implementation notes

Gold verifier can be used for threshold tuning on dev, but never on calibration fit and never during test selection. Логировать это явно, потому что иначе рецензент спросит, где именно вы подсмотрели правильный ответ. И будет прав, мерзавец.

### Unit tests

```racket
(define s1 (make-split tasks 42))
(define s2 (make-split tasks 42))
(check-equal? s1 s2)
(check-true (disjoint? (split-calibration s1) (split-test s1)))
```

### Integration tests

- Run fixture with 6 tasks: 2 calibration, 2 dev, 2 test.
- Check output dirs: `calibration/`, `dev/`, `test/`, `models/`, `metrics.csv`.

### Definition of Done (DoD)

- Split deterministic.
- Test gold not used before final evaluation.
- DS model and thresholds saved.

---
