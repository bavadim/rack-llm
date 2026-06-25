# T-076. Сделать `paper-full` skeleton

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

Добавить skeleton для полного эксперимента с локальной моделью: команда, config template, expected outputs. Если модель не указана, команда должна завершиться понятной ошибкой.

### В скоупе

- `configs/paper-full.example.json`.
- `make paper-full`.
- Checks for local model path.
- Output directory convention.

### Не в скоупе

- Запуск полного эксперимента в CI.
- Скачивание модели.

### Публичные интерфейсы

```bash
RACK_LLM_MODEL=/models/qwen.gguf make paper-full
```

### Unit tests

```bash
unset RACK_LLM_MODEL
make paper-full
# expected: clear error, non-zero exit
```

### Integration tests

Manual only with local GGUF.

### Definition of Done (DoD)

- Full experiment path documented.
- Missing model error clear.
- Config template contains budgets, seed, provider mode, split ratios.

---
