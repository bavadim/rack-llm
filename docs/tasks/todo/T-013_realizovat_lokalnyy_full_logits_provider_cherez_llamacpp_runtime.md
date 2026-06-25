# T-013. Реализовать локальный full-logits provider через llama.cpp runtime

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 10 рабочих дней

### SMART goal

Реализовать локальный provider, который возвращает full-vocab logits для следующего токена из GGUF-модели через llama.cpp runtime. Provider должен работать без HTTP API и поддерживать deterministic seed/config metadata.

### В скоупе

- `providers/llama-local-provider.rkt`.
- Full-vocab logits vector.
- Tokenize/detokenize.
- Model metadata: model id/hash, vocab size.
- Минимальный KV/cache или session state.
- Smoke-test на маленькой GGUF-модели, если модель доступна локально.

### Не в скоупе

- GPU optimization.
- Chat template zoo.
- Streaming generation.
- Multi-model batching.
- Production-grade memory management.

### Публичные интерфейсы

```racket
(: make-llama-local-provider
   (->* (#:model-path Path-String)
        (#:seed Integer
         #:context-size Natural
         #:threads Natural
         #:runtime (U 'ffi 'stdio-sidecar)
         #:chat-template (Option String))
        provider))
```

### Implementation notes

Реализация может идти двумя путями:

#### Вариант A: FFI к `libllama`

- Использовать Racket FFI.
- Вызвать функции загрузки модели/context.
- Для prefix выполнить tokenize/eval.
- Получить logits через `llama_get_logits` или эквивалент runtime.
- Скопировать logits в `FlVector`/`Vectorof Flonum`.

Плюсы: меньше накладных расходов и точный контроль. Минусы: требуется аккуратное управление lifetime объектов FFI.

#### Вариант B: локальный stdio sidecar

- Написать маленький C++/Python sidecar вокруг llama.cpp/llama-cpp-python.
- Протокол через stdin/stdout, например JSON lines или MessagePack.
- Команды: `load`, `tokenize`, `detokenize`, `next_logits`, `reset`, `close`.
- Не HTTP. Это локальный runtime с полными логитами.

Плюсы: проще отладить. Минусы: IPC overhead. Для статьи допустимо, если trace считает overhead отдельно.

Минимальный протокол sidecar:

```json
{"op":"next_logits","session":"s1","prompt":"...","prefix":"..."}
{"ok":true,"vocab_size":32000,"logits_b64":"...","elapsed_ms":12.3}
```

### Unit tests

Без реальной модели:

```racket
(define fake (make-llama-sidecar-provider #:process fake-process))
(check-equal? (provider-info-mode (provider-info fake)) 'exact-full-vocab)
(check-equal? (vector-length (logits-result-logits ((provider-next-logits fake) '() "" st))) 5)
```

С parser-тестом sidecar protocol:

```racket
(check-equal? (decode-logits-response sample-json) expected-logit-vector)
(check-exn exn:fail? (lambda () (decode-logits-response malformed-json)))
```

### Integration tests

Если `RACK_LLM_TEST_GGUF` задан:

```bash
RACK_LLM_TEST_GGUF=/path/to/tiny.gguf make test-llama-local
```

Проверки:

- `vocab-size > 0`.
- `vector-length(logits) = vocab-size`.
- Два одинаковых запроса с одинаковым state/seed дают одинаковые logits в пределах tolerance.
- `softmax(logits)` конечен и нормируется.

### Definition of Done (DoD)

- Provider возвращает full-vocab logits.
- Provider не использует HTTP top-logprobs endpoint.
- Есть mock tests без модели.
- Есть optional integration test с локальной GGUF.
- Trace сохраняет время provider-а и размер vocab.

---
