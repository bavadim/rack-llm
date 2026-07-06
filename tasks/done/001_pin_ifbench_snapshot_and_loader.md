# 001. Зафиксировать snapshot IFBench и сделать загрузчик данных

## SMART goal

Зафиксировать воспроизводимый snapshot IFBench и подготовить локальный канонический JSONL, который будет использоваться всеми последующими экспериментами. Результат должен быть готов за 1 рабочий день и не должен запускать LLM.

## Зачем это нужно

Все эксперименты должны ссылаться на один и тот же набор примеров, иначе результаты превратятся в кашу с красивыми графиками. IFBench содержит prompts, `instruction_id_list`, `kwargs` и official verification functions; эти поля нужны для построения hard-грамматик и soft/noisy rules.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

## Scope

- Скачать/склонировать IFBench.
- Зафиксировать commit hash репозитория IFBench.
- Загрузить `data/IFBench_test.jsonl`.
- Для каждой строки сохранить поля:
  - `key`
  - `prompt`
  - `instruction_id_list`
  - `kwargs`
  - `raw_row_sha256`
- Проверить, что все `instruction_id` присутствуют в `instructions_registry.py`.
- Сохранить файл `data/ifbench_snapshot.jsonl`.
- Сохранить метаданные в `data/ifbench_snapshot_meta.json`.

## Out of scope

- Генерация ответов моделью.
- Конвертация constraints в DSL.
- Запуск official verifier.
- Любые эксперименты по скорости или качеству.

## Expected files

```text
data/ifbench_snapshot.jsonl
data/ifbench_snapshot_meta.json
```

## Required schema: `ifbench_snapshot.jsonl`

```json
{
  "key": "0",
  "prompt": "...",
  "instruction_id_list": ["count:keywords_multiple"],
  "kwargs": [{"keyword1": "kaleidoscope", "keyword2": "nebula"}],
  "raw_row_sha256": "..."
}
```

## Required schema: `ifbench_snapshot_meta.json`

```json
{
  "ifbench_repo_url": "https://github.com/allenai/IFBench",
  "ifbench_commit": "<commit hash>",
  "source_file": "data/IFBench_test.jsonl",
  "num_rows": 397,
  "num_unique_instruction_ids": 58,
  "created_at_utc": "..."
}
```

`num_rows` и `num_unique_instruction_ids` должны вычисляться кодом, не хардкодить, даже если очень хочется порадовать себя легкой победой.

## Unit tests

- `test_snapshot_jsonl_is_valid`: каждая строка валидный JSON.
- `test_required_fields_present`: у каждой строки есть `key`, `prompt`, `instruction_id_list`, `kwargs`.
- `test_registry_coverage`: каждый `instruction_id` найден в registry.
- `test_hash_stable`: `raw_row_sha256` одинаков при повторном запуске.

## DoD

- `data/ifbench_snapshot.jsonl` создан.
- `data/ifbench_snapshot_meta.json` создан.
- Все unit tests проходят.
- В метаданных указан commit IFBench.
- Задача не содержит кода генерации и не импортирует модель.
