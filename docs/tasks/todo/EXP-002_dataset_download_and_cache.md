# EXP-002 — Загрузка датасетов и локальный кеш

## SMART goal

За 2 рабочих дня сделать notebook, который скачивает/подключает открытые датасеты для экспериментов и сохраняет локальные processed-файлы с фиксированной версией.

## Notebook

`experiments/notebooks/002_dataset_download_and_cache.ipynb`

## Datasets

### IFBench

- Main source: `https://github.com/allenai/IFBench`
- Dataset collection: указана в README IFBench на HuggingFace.
- Что нужно: `IFBench_test.jsonl`, official verification functions.
- Назначение: главный эксперимент Weak-IFBench.

### IFEval

- Source: `https://github.com/google-research/google-research/tree/master/instruction_following_eval`
- Назначение: sanity check, не главный результат.

### JSONSchemaBench

- Source: `https://github.com/guidance-ai/jsonschemabench`
- HF mirror: `https://huggingface.co/datasets/epfl-dlab/JSONSchemaBench`
- Назначение: structured generation и grammar control.

### BFCL

- Source: `https://github.com/ShishirPatil/gorilla/tree/main/berkeley-function-call-leaderboard`
- Package: `bfcl-eval`
- Назначение: function calling / structured action generation.

## Scope

- Скачать или подключить датасеты.
- Сохранить в `experiments/data/raw/<dataset>/`.
- Создать normalized preview в `experiments/data/processed/<dataset>/sample.jsonl`.
- Для каждого датасета сохранить `dataset_metadata.json`:
  - URL;
  - commit/hash/version, если доступно;
  - license, если указана;
  - число примеров;
  - дата загрузки;
  - поля записи.

## Out of scope

- Не запускать модели.
- Не писать слабые эвристики.
- Не оценивать результаты.

## Implementation notes

- Для HF использовать `datasets.load_dataset`, если датасет доступен через `datasets`.
- Для GitHub использовать shallow clone:
  ```bash
  git clone --depth 1 <url>
  ```
- Если датасет большой, в notebook должна быть переменная:
  ```python
  DOWNLOAD_FULL = False
  ```
  При `False` качаем/готовим только sample для проверки пайплайна.
- Все внешние пути задавать через `EXPERIMENT_DATA_DIR`.

## Unit tests

Создать `experiments/tests/test_dataset_cache.py`.

Тесты:

1. `dataset_metadata.json` существует для IFBench.
2. У IFBench sample есть поля `prompt`, `constraints` или эквивалентные поля official schema.
3. У JSONSchemaBench sample есть поле `schema`.
4. У BFCL sample есть prompt и function/tool definitions.

## Integration test

Notebook должен создать:

```text
experiments/data/processed/
  ifbench/sample.jsonl
  ifeval/sample.jsonl
  jsonschemabench/sample.jsonl
  bfcl/sample.jsonl
```

## Expected output format

`experiments/results/EXP-002/summary.csv`:

| dataset | n_raw | n_sample | source_url | version_or_commit | status |
|---|---:|---:|---|---|---|

## DoD

- Notebook запускается на чистой машине после установки зависимостей.
- Для каждого датасета есть sample и metadata.
- В README указано, как скачать full dataset.
- Если датасет недоступен, notebook должен завершаться понятной ошибкой с URL, а не «KeyError: lol».
