# T-074. Добавить developer checklist для PR

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 1 рабочий день

### SMART goal

Добавить `.github/pull_request_template.md` или локальный `docs/pr-checklist.md` с пунктами: tests, docs, trace, IO boundary, deterministic seed, provider mode.

### В скоупе

- PR checklist.
- Review expectations.

### Не в скоупе

- GitHub Actions configuration, если ее нет.

### Публичные интерфейсы

Файл:

```text
.github/pull_request_template.md
```

### Unit tests

Не применимо.

### Integration tests

Не применимо.

### Definition of Done (DoD)

- Checklist существует.
- В нем есть пункты про functional style и provider modes.

---
