# EXP-003 — Общие метрики экспериментов

## SMART goal

За 1–2 рабочих дня реализовать общие метрики для main experiment и вспомогательных экспериментов, чтобы все notebooks считали одно и то же, а не каждый свой маленький Вавилон.

## Notebook

`experiments/notebooks/003_metrics_library.ipynb`

## Scope

Добавить `experiments/src/metrics.py`:

```python
def gold_success_at_b(tasks: list[dict], budget: int) -> float: ...
def oracle_at_b(tasks: list[dict], budget: int) -> float: ...
def selection_efficiency(gold_success: float, oracle: float) -> float: ...
def constraint_success(tasks: list[dict]) -> float: ...
def duplicate_rate(candidates: list[str]) -> float: ...
def brier_score(probs: list[float], labels: list[int]) -> float: ...
def expected_calibration_error(probs: list[float], labels: list[int], n_bins: int = 10) -> float: ...
def auroc_safe(probs: list[float], labels: list[int]) -> float | None: ...
```

## Definitions

Для задачи \(i\), бюджета \(B\), выбранного системой ответа \(y_i^*\), gold-verifier \(g_i\):

\[
GoldSuccess@B = \frac{1}{N}\sum_i g_i(y_i^*)
\]

\[
Oracle@B = \frac{1}{N}\sum_i \mathbf{1}[\exists m \le B: g_i(y_i^{(m)})=1]
\]

\[
SelectionEfficiency@B = \frac{GoldSuccess@B}{Oracle@B}
\]

Если `Oracle@B = 0`, вернуть `None`, не делить на ноль ради науки.

## Out of scope

- Не реализовывать сами verifiers.
- Не обучать Dawid–Skene.
- Не запускать модель.

## Unit tests

Создать `experiments/tests/test_metrics.py`.

Минимальные тесты:

1. Для 2 задач, где одна успешна, `GoldSuccess@B = 0.5`.
2. Если среди кандидатов есть gold-pass, `Oracle@B` считает это независимо от выбранного ответа.
3. `SelectionEfficiency@B` возвращает `None` при `Oracle@B=0`.
4. `duplicate_rate(["a", "a", "b"]) == 1 - 2/3`.
5. `brier_score([0, 1], [0, 1]) == 0`.
6. `ECE` возвращает число в `[0,1]`.

## Expected output format

`experiments/results/EXP-003/summary.csv`:

| metric | test_case | value | expected | status |
|---|---|---:|---:|---|

## DoD

- Все функции покрыты unit tests.
- Notebook демонстрирует расчет на игрушечном наборе.
- Функции не зависят от pandas, кроме отдельного блока агрегации в notebook.
