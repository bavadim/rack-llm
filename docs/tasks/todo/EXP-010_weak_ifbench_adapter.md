# EXP-010 — Адаптер Weak-IFBench

## SMART goal

За 3 рабочих дня построить адаптер, который превращает IFBench в наш основной экспериментальный формат: prompt + constraints + hidden official verifier + место для слабых эвристик.

## Notebook

`experiments/notebooks/010_weak_ifbench_adapter.ipynb`

## Hypothesis

IFBench можно использовать как основу новой задачи **Programmatic Weak-Constraint Generation**, если официальный verifier спрятать от метода и использовать только для оценки. Тогда задача становится: сгенерировать и выбрать ответ по слабым эвристикам, а качество измерить скрытым gold-verifier.

## Dataset

- IFBench GitHub: `https://github.com/allenai/IFBench`
- В IFBench есть 58 OOD constraints с verification functions и тестовые данные.
- Официальная метрика IFBench в статье/README: prompt-level loose accuracy.
- В нашем протоколе official verifier используется только как `gold_verifier`.

## Scope

Создать `experiments/src/weak_ifbench.py`:

```python
@dataclass(frozen=True)
class WeakIFBenchTask:
    task_id: str
    prompt: str
    constraints: list[dict]
    gold_verifier_id: str
    metadata: dict

def load_ifbench_tasks(path: Path, limit: int | None = None) -> list[WeakIFBenchTask]: ...
def run_gold_verifier(task: WeakIFBenchTask, output: str) -> dict:
    # returns {"prompt_pass": bool, "constraint_pass": dict[str, bool]}
```

Notebook должен:

1. Загрузить IFBench test sample.
2. Для каждой записи извлечь prompt и constraints.
3. Подключить официальный verifier.
4. Проверить verifier на 3 искусственных ответах:
   - явно правильный, если легко создать;
   - явно неправильный;
   - пустой ответ.

## Out of scope

- Не писать слабые эвристики.
- Не запускать LLM.
- Не считать Gumbel/DS.

## Implementation notes

- Не переписывать official verifier вручную. Импортировать из IFBench.
- Если IFBench verifier требует специальный формат ответа, сделать адаптер:
  ```python
  def normalize_model_output(text: str) -> str
  ```
- Если правильный artificial output сложно создать, оставить только negative smoke tests и отметить это в `known_limitations.md`.

## Unit tests

`experiments/tests/test_weak_ifbench_adapter.py`:

1. `load_ifbench_tasks(limit=5)` возвращает 5 задач.
2. У каждой задачи непустой `prompt`.
3. `run_gold_verifier(task, "")` возвращает dict с `prompt_pass`.
4. Verifier не падает на unicode, markdown, многострочном тексте.

## Expected output format

`experiments/results/EXP-010/tasks_preview.jsonl`:

```json
{
  "task_id": "...",
  "prompt": "...",
  "n_constraints": 3,
  "constraint_types": ["..."],
  "gold_verifier_id": "..."
}
```

`summary.csv`:

| n_tasks | n_constraint_types | verifier_import_status | n_smoke_passed |
|---:|---:|---|---:|

## DoD

- Можно получить список задач WeakIFBenchTask.
- Можно вызвать gold verifier для любого кандидата.
- Gold verifier не используется внутри выбора кандидата, только в evaluation cell.
