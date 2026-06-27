# T-051. Реализовать repair-prompt mode как отдельный новый поток

**Category:** Resampling, tracing и метрики  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 5 рабочих дней

### SMART goal

Добавить опциональный режим, где диагностика отклоненного кандидата добавляется в prompt, после чего запускается новый Gumbel-stream с новым контекстом. В trace должно быть явно видно, что это новый stream, а не продолжение старого without-replacement процесса.

### В скоупе

- Repair context builder.
- Stream id.
- Diagnostics injection.
- Max repair rounds.

### Не в скоупе

- Автоматическое улучшение правил.
- RL/RLAIF.

### Публичные интерфейсы

```racket
(struct repair-config
  ([enabled? : Boolean]
   [max-rounds : Natural]
   [diagnostics-limit : Natural])
  #:transparent)

(: make-repair-transcript
   (-> EvaluatedProgram candidate acceptance-decision EvaluatedProgram))
```

### Implementation notes

Текст диагностики должен быть коротким и структурированным:

```text
Previous candidate was rejected.
Rule failures:
- word_count_split: expected 50 words, got 61
- forbidden_phrase_regex: found banned phrase
Regenerate a corrected answer.
```

### Unit tests

```racket
(define repaired (make-repair-transcript transcript bad-candidate decision))
(check-true (string-contains? (render repaired) "Previous candidate was rejected"))
(check-true (string-contains? (render repaired) "word_count"))
```

### Integration tests

- Trace has `stream-id=1` before repair and `stream-id=2` after repair.
- Candidate ranks restart inside new stream.

### Definition of Done (DoD)

- Repair mode optional and off by default in main benchmark unless ablation says otherwise.
- Trace distinguishes same-stream resampling and repair-stream restart.

---
