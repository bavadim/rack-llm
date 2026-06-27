# EXP-013 — Dawid–Skene-агрегация слабых правил

## SMART goal

За 5 рабочих дней реализовать и проверить Dawid–Skene-агрегацию weak-rule outputs для Weak-IFBench, затем сравнить ее с majority/equal weights.

## Notebook

`experiments/notebooks/013_dawid_skene_weak_rule_aggregation.ipynb`

## Hypothesis

Dawid–Skene должен лучше majority/equal weights выбирать кандидаты, когда слабые эвристики имеют разную точность, конфликтуют и часто возвращают `abstain`.

## Input

- `rule_outputs.jsonl` из EXP-011/EXP-012.
- `raw_candidates.jsonl` из EXP-012.
- Gold labels используются только:
  - для финальной оценки;
  - для ориентации скрытого класса на dev split;
  - не для EM-fit на test.

## Scope

Реализовать `experiments/src/dawid_skene.py`:

```python
class DawidSkeneBinary:
    def __init__(self, n_iter: int = 50, smoothing: float = 1e-3): ...
    def fit(self, votes: pd.DataFrame) -> "DawidSkeneBinary": ...
    def predict_proba(self, votes: pd.DataFrame) -> pd.Series: ...
    def to_json(self) -> dict: ...
    @classmethod
    def from_json(cls, data: dict) -> "DawidSkeneBinary": ...
```

Где `votes` имеет поля:

| column | meaning |
|---|---|
| item_id | candidate или candidate-constraint id |
| rule_id | id эвристики |
| vote | accept/reject/abstain |

## Mathematical target

Для кандидата \(y\):

\[
h_k(y) \in \{accept, reject, abstain\}
\]

\[
\Pi^{(k)}_{z,a}=P(h_k(y)=a\mid z)
\]

\[
\eta(y)=P(z=1\mid h_1(y),\ldots,h_K(y))
\]

## Out of scope

- Не использовать Snorkel.
- Не добавлять correlation-aware label model.
- Не менять weak rules.

## Implementation notes

- Использовать EM:
  - E-step: posterior \(P(z=1|votes)\).
  - M-step: обновить confusion matrices.
- Добавить smoothing, иначе junior первым же делом получит `log(0)` и решит, что это философия.
- Ориентация классов:
  - на dev split выбрать класс, у которого больше agreement с small gold dev;
  - либо использовать high-precision anchor rule.
- Поддержать `abstain` как третий исход, не выкидывать его.

## Metrics

Calibration:

- AUROC
- AUPRC
- Brier
- ECE

End-to-end:

- `GoldSuccess@B`
- `SelectionEfficiency@B`
- `AcceptedPrecision`
- `AcceptedRecall`

## Experiment plan

1. Разделить задачи: calibration/dev/test.
2. На calibration fit DS без gold labels.
3. На dev выбрать threshold \(	au\) и ориентацию класса.
4. На test сравнить selectors:
   - majority;
   - equal weights;
   - DS posterior;
   - oracle verifier upper bound.
5. Повторить для бюджетов \(B=[1,2,4,8,16]\).

## Expected output format

`ds_model.json`:

```json
{
  "classes": [0, 1],
  "outcomes": ["accept", "reject", "abstain"],
  "priors": {"0": 0.4, "1": 0.6},
  "confusion": {
    "word_count_split": {
      "0": {"accept": 0.1, "reject": 0.8, "abstain": 0.1},
      "1": {"accept": 0.7, "reject": 0.2, "abstain": 0.1}
    }
  }
}
```

`summary.csv`:

| selector | budget | gold_success | selection_efficiency | auroc | brier | ece |
|---|---:|---:|---:|---:|---:|---:|

## Expected result

- DS должен иметь Brier/ECE лучше majority score.
- DS должен повысить `SelectionEfficiency@B` относительно equal weights, особенно при \(B=8,16\).
- Если DS хуже majority, вывести таблицу правил с confusion matrices и вероятной причиной: коррелированные правила, неправильная ориентация класса, слабая coverage.

## Unit tests

1. На синтетике с 3 правилами DS восстанавливает более надежное правило.
2. `predict_proba` возвращает значения в `[0,1]`.
3. `to_json/from_json` сохраняют одинаковые probabilities.
4. При всех `abstain` возвращается prior, а не NaN.

## DoD

- DS fit/predict работает.
- Есть comparison table с majority/equal/DS.
- Есть calibration plot или reliability table.
