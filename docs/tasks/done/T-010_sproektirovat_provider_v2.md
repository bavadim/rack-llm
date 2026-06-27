# T-010. Спроектировать `Provider v2`

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Спроектировать и реализовать минимальный typed API для provider-слоя, который поддерживает full-vocab logits, top-K/truncated режим, токенизацию, детокенизацию, seed и явное состояние модели. API должен заменить старый `TokenOracle`, но не ломать его сразу: нужен compatibility adapter.

### В скоупе

- Новый модуль `providers/provider-v2.rkt`.
- Типы `TokenId`, `LogitVector`, `ProviderMode`, `ProviderState`, `ProviderTrace`.
- Функции для `tokenize`, `detokenize`, `next-logits`, `provider-reset`.
- Adapter из старого `TokenOracle` в truncated provider только для совместимости.

### Не в скоупе

- Реализация llama.cpp provider.
- Реализация OpenAI provider.
- Grammar masking.
- Sampling algorithm.

### Публичные интерфейсы

```racket
#lang typed/racket/base

(define-type TokenId Natural)
(define-type Logit Flonum)
(define-type LogitVector (Vectorof Logit))
(define-type ProviderMode (U 'exact-full-vocab 'truncated-top-k 'compat-no-logits))

(struct provider-info
  ([name : Symbol]
   [mode : ProviderMode]
   [model-id : String]
   [model-hash : (Option String)]
   [vocab-size : Natural])
  #:transparent)

(struct provider-state ([opaque : Any]) #:transparent)

(struct provider-trace
  ([prompt-tokens : Natural]
   [prefix-tokens : Natural]
   [cache-hit? : Boolean]
   [elapsed-ms : Nonnegative-Flonum]
   [truncated-mass : (Option Flonum)])
  #:transparent)

(struct logits-result
  ([logits : LogitVector]
   [state : provider-state]
   [trace : provider-trace])
  #:transparent)

(define-type LogitProvider
  (-> EvaluatedProgram String provider-state logits-result))

(struct provider
  ([info : provider-info]
   [initial-state : provider-state]
   [tokenize : (-> String (Listof TokenId))]
   [detokenize : (-> (Listof TokenId) String)]
   [next-logits : LogitProvider])
  #:transparent)
```

### Implementation notes

Старый `TokenOracle` возвращает конечный список `token-candidate`. Для новой статьи этого мало: exact-семплирование требует весь словарь или явно описанный truncated mode. Поэтому compatibility adapter должен иметь mode `compat-no-logits` или `truncated-top-k`, а не притворяться exact-provider.

Provider state должен быть явным значением. Нельзя прятать model/session/cache в глобальном состоянии: это нарушает воспроизводимость экспериментов.

### Unit tests

`tests/unit/provider-v2-test.rkt`:

```racket
(define p (make-mock-provider #:vocab '("a" "b") #:logits '#(0.0 -1.0)))
(define r ((provider-next-logits p) '() "" (provider-initial-state p)))
(check-equal? (vector-length (logits-result-logits r)) 2)
(check-equal? ((provider-tokenize p) "ab") '(0 1))
(check-equal? ((provider-detokenize p) '(0 1)) "ab")
(check-equal? (provider-info-mode (provider-info p)) 'exact-full-vocab)
```

### Integration tests

- Старый README JSON example запускается через `token-oracle->provider` adapter.
- Новый mock-provider запускается через новый sampler smoke-test.

### Definition of Done (DoD)

- Новый API реализован и экспортирован.
- Есть mock-provider для unit tests.
- Старый `TokenOracle` оборачивается, но помечается не exact.
- Документация `docs/provider-v2.md` содержит пример использования.

---
