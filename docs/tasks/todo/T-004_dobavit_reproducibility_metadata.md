# T-004. Добавить reproducibility metadata

**Category:** Инфраструктура  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 2 рабочих дня

### SMART goal

Добавить структуру `run-metadata`, которая сохраняет seed, git commit, model id/hash, provider mode, grammar id, rule set id и версию библиотеки для каждого запуска.

### В скоупе

- Структура metadata.
- Сериализация в JSON.
- Добавление metadata в trace.

### Не в скоупе

- Полный trace кандидатов.
- Экспорт таблиц статьи.

### Публичные интерфейсы

```racket
(struct run-metadata
  ([run-id : String]
   [seed : Integer]
   [library-version : String]
   [git-commit : (Option String)]
   [provider-name : Symbol]
   [provider-mode : Symbol]
   [model-id : String]
   [model-hash : (Option String)]
   [grammar-id : String]
   [rule-set-id : String])
  #:transparent)

(: run-metadata->json (-> run-metadata JSExpr))
(: current-git-commit (-> (Option String)))
```

### Implementation notes

`current-git-commit` может читать `git rev-parse HEAD`, но это IO, поэтому функция живет в `traces/` или `experiments/`, не в core.

### Unit tests

```racket
(define m (run-metadata "r1" 42 "0.1" #f 'mock 'exact "mock" #f "g1" "h1"))
(check-equal? (hash-ref (run-metadata->json m) 'seed) 42)
(check-equal? (hash-ref (run-metadata->json m) 'provider_mode) "exact")
```

### Integration tests

- Запустить smoke run с mock-provider.
- Проверить, что `trace.jsonl` начинается с metadata event.

### Definition of Done (DoD)

- Metadata сохраняется во всех experiment runs.
- Metadata содержит provider mode: `exact`, `truncated`, `compat`.
- Нет скрытой зависимости от git в unit tests.

---
