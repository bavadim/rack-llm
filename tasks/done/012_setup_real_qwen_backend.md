# 012. Настроить real Qwen3.5 backend для paper-grade экспериментов

## SMART goal

Подготовить воспроизводимую локальную CUDA-среду для real-model benchmark на `Qwen/Qwen3.5-4B`. Задача должна завершиться рабочей venv, загруженной моделью, проверкой CUDA и metadata-файлом. Если backend нельзя подготовить, задача должна fail-closed через `MISSING_BACKEND.md`, а не создавать экспериментальные метрики.

## Зачем это нужно

Текущие hard/soft результаты являются pilot/smoke: hard использует witness/spec сравнение, soft использует synthetic candidate pool. Для нормальной статьи нужен реальный локальный LLM backend, единый для Racket sidecar, Guidance и Outlines.

## Scope

- Создать isolated venv:

```text
.venv-realbench
```

- Установить:

```text
torch CUDA wheel
transformers
accelerate
huggingface_hub
guidance
outlines
scipy
pandas
```

- Скачать модель:

```text
Qwen/Qwen3.5-4B
```

в:

```text
/mnt/storage/models/qwen/Qwen3.5-4B
```

- Зафиксировать:
  - Python version;
  - package versions;
  - CUDA availability;
  - GPU name and memory;
  - model path;
  - model revision/hash where available.

## Out of scope

- Не запускать IFBench benchmark.
- Не писать sidecar.
- Не запускать Guidance/Outlines methods.
- Не использовать Qwen 0.8B для финальных claims. Маленькая модель допустима только как smoke fallback и должна быть явно помечена.

## How

- Добавить setup/check script в:

```text
experiments/012_real_model_benchmark/code/setup_real_backend.py
```

- Script должен:
  - создать или проверить `.venv-realbench`;
  - проверить `torch.cuda.is_available()`;
  - загрузить tokenizer/model;
  - выполнить короткий forward pass;
  - записать metadata.

- Основной runner `run_real_model_benchmark.py` должен читать эту metadata и продолжать fail-closed, если backend не готов.

## Required outputs

```text
experiments/012_real_model_benchmark/results/backend_metadata.json
data/012_backend_metadata.json
```

При ошибке:

```text
experiments/012_real_model_benchmark/results/MISSING_BACKEND.md
data/MISSING_BACKEND.md
```

## Unit tests

- `test_backend_metadata_schema`: metadata содержит model, CUDA, GPU, package versions.
- `test_cuda_available_for_real_backend`: CUDA доступна, если task помечен success.
- `test_missing_backend_is_fail_closed`: при отсутствии model/env не создаются benchmark metrics.

## DoD

- `.venv-realbench` создана.
- `torch.cuda.is_available()` проходит в venv.
- `Qwen/Qwen3.5-4B` tokenizer/model загружаются без OOM.
- `backend_metadata.json` создан и содержит воспроизводимые версии.
- Если setup невозможен, создан только `MISSING_BACKEND.md`, без raw/summary результатов.
