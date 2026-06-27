# T-052. Реализовать trace schema

**Category:** Resampling, tracing и метрики  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 5 рабочих дней

### SMART goal

Создать JSONL trace format, который сохраняет run metadata, candidate data, rule observations, DS posteriors, acceptance decision и sampler stats.

### В скоупе

- `traces/trace.rkt`.
- `traces/writer.rkt`.
- JSON serialization.
- Stable schema version.

### Не в скоупе

- UI viewer.
- Database storage.

### Публичные интерфейсы

```racket
(struct candidate-trace
  ([run-id : String]
   [stream-id : Natural]
   [rank : Natural]
   [candidate-hash : String]
   [text : String]
   [tokens : (Listof TokenId)]
   [logprob : Flonum]
   [gumbel-score : Flonum]
   [rule-observations : (Listof rule-observation)]
   [constraint-posteriors : (HashTable Symbol Flonum)]
   [accepted? : Boolean]
   [diagnostics : (Listof String)])
  #:transparent)

(: write-trace-event (-> Output-Port Symbol Any Void))
(: candidate-trace->json (-> candidate-trace JSExpr))
```

### Implementation notes

Не писать весь огромный текст в каждую таблицу метрик. В trace можно хранить text, а metrics reader может использовать hash. Для приватных production runs добавить опцию `#:redact-text?`.

### Unit tests

```racket
(define j (candidate-trace->json sample-trace))
(check-equal? (hash-ref j 'schema_version) "1")
(check-equal? (hash-ref j 'accepted) #t)
```

### Integration tests

- `resample-until-accepted` writes trace with metadata + candidates.
- Trace reader reconstructs selected candidate rank.

### Definition of Done (DoD)

- Trace schema versioned.
- JSONL files readable line-by-line.
- Text redaction option exists.

---
