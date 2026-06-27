# T-072. Написать `docs/provider-v2.md`

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 3 рабочих дня

### SMART goal

Документировать provider v2, различие exact/truncated/compat modes и требования к локальному provider для статьи.

### В скоупе

- API reference.
- Example mock-provider.
- Example llama-local provider.
- OpenAI limitations.
- Reproducibility metadata.

### Не в скоупе

- Полный гайд по сборке llama.cpp.
- Performance tuning.

### Публичные интерфейсы

Документ:

```text
docs/provider-v2.md
```

### Implementation notes

Главное сообщение: OpenAI top-logprobs provider нельзя использовать для exact distribution experiments. Локальный runtime с full logits обязателен.

### Unit tests

Не применимо.

### Integration tests

- Links in docs checked by markdown link checker, если добавлен.

### Definition of Done (DoD)

- Документ объясняет все provider modes.
- Есть section `Why full-vocab logits are required`.

---
