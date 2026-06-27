# T-015. Добавить prompt rendering policy для локальных моделей

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 3 рабочих дня

### SMART goal

Сделать prompt rendering явным и тестируемым: transcript + prefix должны преобразовываться в строку одинаково для mock, llama-local и compatibility providers.

### В скоупе

- `providers/prompt-rendering.rkt`.
- Plain renderer, chat-template renderer.
- Тесты на transcript roles.

### Не в скоупе

- Полная поддержка всех chat templates.
- Auto-detect template по GGUF metadata.

### Публичные интерфейсы

```racket
(define-type PromptRenderer (-> EvaluatedProgram String String))
(: plain-renderer PromptRenderer)
(: make-chat-template-renderer (-> String PromptRenderer))
```

### Implementation notes

На первом этапе plain renderer достаточно. Главное — убрать размазанный render logic из каждого backend.

### Unit tests

```racket
(check-equal?
 (plain-renderer (list (user (list (lit "hi")))) "prefix")
 "user: hi\nprefix")
```

### Integration tests

- OpenAI compat и llama-local используют один renderer contract.

### Definition of Done (DoD)

- Renderer вынесен из backend-ов.
- Provider tests проверяют prompt string.
