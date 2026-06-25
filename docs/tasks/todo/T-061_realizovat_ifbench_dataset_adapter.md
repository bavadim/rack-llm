# T-061. Реализовать IFBench dataset adapter

**Category:** Weak-IFBench runner  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 6 рабочих дней

### SMART goal

Добавить adapter, который загружает задачи IFBench из локального JSON/JSONL-экспорта и предоставляет prompt, список constraints и gold verifier interface.

### В скоупе

- `experiments/weak-ifbench/dataset.rkt`.
- Локальный JSONL schema.
- Loader.
- Task struct.
- Gold verifier invocation through local command or embedded verifier wrapper.

### Не в скоупе

- Скачивание dataset из интернета во время тестов.
- Полная поддержка всех IFBench internals на первом этапе.
- Weak heuristics.

### Публичные интерфейсы

```racket
(struct ifbench-task
  ([id : String]
   [prompt : String]
   [constraints : (Listof constraint-spec)]
   [gold-verifier-id : Symbol]
   [metadata : (HashTable Symbol Any)])
  #:transparent)

(struct constraint-spec
  ([id : Symbol]
   [type : Symbol]
   [params : (HashTable Symbol Any)])
  #:transparent)

(: load-ifbench-jsonl (-> Path-String (Listof ifbench-task)))
(: run-gold-verifier (-> ifbench-task String gold-verdict))
```

Gold verdict:

```racket
(struct gold-verdict
  ([prompt-passed? : Boolean]
   [constraint-results : (HashTable Symbol Boolean)]
   [message : (Option String)])
  #:transparent)
```

### Implementation notes

Практичный путь:

1. Отдельным Python script экспортировать IFBench в простой JSONL.
2. Racket runner читает JSONL.
3. Gold verifier вызывается как локальный Python command:

```bash
python verify_ifbench.py --task-id ... --candidate-file ...
```

Это грязнее, чем pure Racket, но быстрее и честнее, чем переписывать весь verifier. В статье это не важно; важна воспроизводимость.

### Unit tests

Fixture `tests/fixtures/weak-ifbench-small.jsonl`:

```racket
(define tasks (load-ifbench-jsonl "tests/fixtures/weak-ifbench-small.jsonl"))
(check-equal? (length tasks) 2)
(check-equal? (ifbench-task-id (first tasks)) "task-1")
(check-true (constraint-spec? (first (ifbench-task-constraints (first tasks)))))
```

Gold verifier fake:

```racket
(check-true (gold-verdict-prompt-passed? (run-gold-verifier fake-task good-answer)))
(check-false (gold-verdict-prompt-passed? (run-gold-verifier fake-task bad-answer)))
```

### Integration tests

- `make test-weak-ifbench-fixture` runs 2–5 tasks with fake provider and fake verifier.

### Definition of Done (DoD)

- Loader works on local JSONL.
- Gold verifier is accessible but not exposed to selection code.
- Tests do not require network.

---
