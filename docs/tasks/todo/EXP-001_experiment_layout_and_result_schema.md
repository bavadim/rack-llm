# EXP-001 — Каркас `experiments/` и единый формат результатов

## SMART goal

За 1 рабочий день создать каркас экспериментальной папки и единый формат результатов, чтобы все следующие notebook писали совместимые файлы, а не набор «final_final_really.csv». Человечество уже страдало, хватит.

## Notebook

`experiments/notebooks/001_experiment_layout.ipynb`

## Scope

- Создать структуру:
  - `experiments/notebooks/`
  - `experiments/data/raw/`
  - `experiments/data/processed/`
  - `experiments/results/`
  - `experiments/src/`
- Добавить Python-модуль `experiments/src/io.py`:
  - `write_jsonl(path, rows)`
  - `read_jsonl(path)`
  - `write_metadata(path, metadata)`
  - `ensure_result_dir(experiment_id) -> Path`
- Добавить Python-модуль `experiments/src/schema.py`:
  - `validate_candidate_row(row)`
  - `validate_summary_row(row)`
- Описать общий result schema в `experiments/README.md`.

## Out of scope

- Не загружать реальные датасеты.
- Не запускать LLM.
- Не реализовывать Dawid–Skene, Gumbel или правила.
- Не менять core-библиотеку.

## Public interfaces

```python
from experiments.src.io import ensure_result_dir, write_jsonl, read_jsonl, write_metadata
from experiments.src.schema import validate_candidate_row, validate_summary_row
```

Минимальная строка `raw_candidates.jsonl`:

```json
{
  "experiment_id": "EXP-014",
  "dataset": "IFBench",
  "task_id": "string",
  "method": "gumbel_ds",
  "budget": 8,
  "candidate_index": 1,
  "candidate_text": "string",
  "accepted_by_method": true,
  "gold_success": false,
  "latency_ms": 1234.5,
  "tokens_out": 120,
  "seed": 42
}
```

## Unit tests

Создать `experiments/tests/test_schema.py`.

Тесты:

1. `validate_candidate_row` принимает строку с обязательными полями.
2. `validate_candidate_row` падает, если нет `task_id`.
3. `write_jsonl/read_jsonl` сохраняет и читает 2 строки без потерь.
4. `ensure_result_dir("EXP-001")` создает папку.

## Integration test

Запустить notebook. Он должен создать:

```text
experiments/results/EXP-001/
  run_metadata.json
  raw_candidates.jsonl
  summary.csv
```

`summary.csv` должен содержать 1 тестовую строку с `experiment_id=EXP-001`.

## Expected output format

`summary.csv`:

| column | type |
|---|---|
| experiment_id | str |
| status | str |
| n_rows_written | int |
| n_rows_read | int |

## DoD

- Notebook запускается сверху вниз.
- `pytest experiments/tests/test_schema.py` проходит.
- `experiments/README.md` содержит schema и пути.
- Нет абсолютных путей вида `/home/user/...`.
