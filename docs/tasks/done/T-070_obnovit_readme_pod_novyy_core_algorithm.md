# T-070. Обновить README под новый core algorithm

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

Обновить README так, чтобы первый пример показывал новый pipeline: grammar -> Gumbel stream -> rules -> acceptance, а не только `lit/select/gen` и клиентский `stream-filter`.

### В скоупе

- Короткое описание библиотеки.
- Minimal example.
- Provider modes.
- Warning про OpenAI/truncated mode.
- Link на docs.

### Не в скоупе

- Полная tutorial-документация.
- Экспериментальные таблицы статьи.

### Публичные интерфейсы

README example должен компилироваться:

```racket
#lang racket
(require rack-llm
         rack-llm/providers/mock
         rack-llm/grammar
         rack-llm/sampling
         rack-llm/rules)
```

### Implementation notes

README должен содержать минимальный runnable example. Если пример нельзя запустить автоматически, он не считается выполненным.

### Unit tests

- Extract code block from README and run as smoke test, если возможно.

### Integration tests

```bash
make test-readme
```

### Definition of Done (DoD)

- README описывает new core algorithm.
- README явно объясняет provider modes.
- README example works with mock-provider.

---
