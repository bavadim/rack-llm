# EXP-011 — Слабые эвристики для Weak-IFBench

## SMART goal

За 4 рабочих дня реализовать повторно используемые слабые эвристики для основных типов IFBench-ограничений. Каждая эвристика должна возвращать `accept/reject/abstain`, а не притворяться богом истины.

## Notebook

`experiments/notebooks/011_weak_heuristics_for_ifbench.ipynb`

## Hypothesis

Для verifiable instruction following можно построить набор слабых программных правил, которые:
1. часто коррелируют с official verifier;
2. ошибаются и конфликтуют;
3. дают материал для Dawid–Skene-агрегации.

## Dataset

Weak-IFBench tasks из `EXP-010`.

## Scope

Создать `experiments/src/weak_rules.py`:

```python
Vote = Literal["accept", "reject", "abstain"]

@dataclass(frozen=True)
class RuleResult:
    rule_id: str
    constraint_id: str
    vote: Vote
    message: str
    metadata: dict

class WeakRule(Protocol):
    rule_id: str
    constraint_types: set[str]
    def __call__(self, task: WeakIFBenchTask, output: str) -> RuleResult: ...
```

Реализовать минимум 12 слабых правил, покрывающих минимум 5 семейств ограничений:

1. `word_count_split`
2. `word_count_regex`
3. `word_count_tokenizer`
4. `phrase_exact`
5. `phrase_lowercase`
6. `phrase_fuzzy`
7. `forbidden_substring`
8. `forbidden_word_boundary`
9. `markdown_heading_regex`
10. `list_item_regex`
11. `json_parse_shallow`
12. `sentence_count_punct`

## Out of scope

- Не использовать official verifier как слабое правило.
- Не писать LLM-judge в этой задаче.
- Не обучать Dawid–Skene.

## Implementation notes

- Каждое правило должно быть шаблоном по типу ограничения, а не уникальной функцией для одного prompt.
- Если правило не применимо к constraint type, оно возвращает `abstain`.
- В `message` писать короткую диагностику: `"expected >= 3 words, got 2 by split()"`.
- Для fuzzy match использовать простую нормализацию + `difflib.SequenceMatcher`, без тяжелых зависимостей.

## Unit tests

`experiments/tests/test_weak_rules.py`:

1. `phrase_exact` принимает текст с точной фразой.
2. `phrase_lowercase` принимает текст с другой капитализацией.
3. `forbidden_substring` отклоняет текст с запрещенной строкой.
4. `word_count_split` возвращает `reject`, если слов меньше минимума.
5. Неприменимое правило возвращает `abstain`.
6. Все `RuleResult.vote` входят в `accept/reject/abstain`.

## Experiment plan

1. Взять sample из 100 IFBench задач.
2. Для каждой задачи создать 3 тестовых кандидата:
   - пустой ответ;
   - короткий ответ;
   - ответ с повторением prompt.
3. Прогнать все слабые правила.
4. Посчитать coverage правил:
   \[
   coverage(h)=P(h(y) \ne abstain)
   \]
5. Посчитать agreement с official verifier на этих тестовых кандидатах как sanity check.

## Metrics

- `rule_coverage`
- `rule_accept_rate`
- `rule_reject_rate`
- `rule_abstain_rate`
- `rough_gold_agreement`

## Expected output format

`rule_outputs.jsonl`:

```json
{
  "task_id": "...",
  "candidate_id": "...",
  "constraint_id": "...",
  "rule_id": "word_count_split",
  "vote": "reject",
  "message": "expected >= 50 words, got 31",
  "gold_constraint_pass": false
}
```

`summary.csv`:

| rule_id | coverage | accept_rate | reject_rate | abstain_rate | rough_gold_agreement |
|---|---:|---:|---:|---:|---:|

## Expected result

- Не менее 5 constraint families имеют слабые правила.
- У большинства правил coverage > 0 на применимых constraint types.
- Agreement не должен быть 1.0: правила должны быть слабыми, иначе это не слабые эвристики, а официальный verifier в маске.

## DoD

- Есть 12 правил.
- Есть таблица coverage.
- Есть примеры конфликтов правил по одной и той же задаче.
