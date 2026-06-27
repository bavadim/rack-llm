# T-012. Пометить OpenAI adapter как compatibility/truncated-only

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 1 рабочий день

### SMART goal

Обновить OpenAI adapter так, чтобы он явно сообщал mode `compat-no-logits` или `truncated-top-k` и не мог использоваться в exact-семплировании или synthetic correctness tests.

### В скоупе

- Adapter к Provider v2.
- Явная ошибка при попытке `require-exact-provider`.
- Документация ограничения.

### Не в скоупе

- Получение full logits из OpenAI API.
- Обход ограничения через многократные запросы.
- Использование OpenAI в основных экспериментах статьи.

### Публичные интерфейсы

```racket
(: make-openai-compat-provider
   (->* ()
        (#:api-key String
         #:model String
         #:top-logprobs Natural)
        provider))

(: require-exact-provider (-> provider Void))
```

### Implementation notes

OpenAI adapter полезен для demo, но не для exact Gumbel distribution. Если API возвращает только top-logprobs, это не full-vocab logits. Значит, exact-tests должны падать с понятной ошибкой:

```text
provider mode truncated-top-k cannot be used for exact distribution tests
```

### Unit tests

```racket
(define p (make-openai-compat-provider #:client fake-client ...))
(check-equal? (provider-info-mode (provider-info p)) 'truncated-top-k)
(check-exn exn:fail? (lambda () (require-exact-provider p)))
```

### Integration tests

- Weak-IFBench runner должен принимать OpenAI provider только с флагом `--allow-truncated-provider`.
- Synthetic exact runner должен отклонять OpenAI provider.

### Definition of Done (DoD)

- OpenAI adapter не маскируется под exact-provider.
- Ошибка понятная.
- README/provider docs предупреждают о режиме совместимости.

---
