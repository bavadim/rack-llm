# T-002. Настроить единый тестовый harness

**Category:** Инфраструктура  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 2 рабочих дня

### SMART goal

Добавить единый test runner и соглашение по тестам, чтобы все новые задачи можно было проверять одной командой `make test`.

### В скоупе

- `make test` запускает unit tests.
- `make test-integration` запускает медленные тесты без внешнего интернета.
- `make lint` хотя бы проверяет compile/typecheck всех Racket-файлов.
- Тесты должны быть deterministic по seed.

### Не в скоупе

- Полный benchmark.
- Запуск локальной LLM в CI.
- Проверка качества на IFBench.

### Публичные интерфейсы

Команды:

```bash
make test
make test-integration
make lint
```

Тестовые helpers:

```racket
(require rack-llm/testing)
(make-deterministic-mock-provider ...)
(check-stream-prefix ...)
```

### Implementation notes

Для Racket достаточно `raco test tests/unit`. Для deterministic streams добавить mock-provider, который выдает заранее заданные логиты. Без mock-provider каждый unit test превратится в сеанс спиритизма с LLM.

### Unit tests

Проверить сам helper:

```racket
(define p (make-deterministic-mock-provider ...))
(check-equal? (provider-next-logits p state) expected-logits)
```

### Integration tests

- `make test` должен падать при сломанной сигнатуре mock-provider.
- `make lint` должен падать на type error.

### Definition of Done (DoD)

- Все команды есть в `Makefile`.
- Все команды документированы в `docs/development.md`.
- CI или локальный скрипт запускает их в правильном порядке.

---
