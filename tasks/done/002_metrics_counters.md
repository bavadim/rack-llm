# Задача 002. Добавить metrics counters для hot path

Исходный номер в `tasks.md`: 019.


## SMART goal

За 1 рабочий день добавить счетчики производительности, которые позволяют увидеть, что генерация больше не работает квадратично.

## Scope

Добавить metrics:

```racket
vocab-size
candidate-count-total
candidate-count-per-step
provider-calls
llm-time-ms
rule-time-ms
sampling-time-ms
runtime-step-calls
check-calls-in-sampling
parse-guide-calls-in-sampling
regex-calls
watcher-step-calls
dead-token-count
allowed-token-count
fast-forward-tokens
```

## Out of scope

Не входит:

* exporter в Prometheus;
* experiment JSONL runners;
* графики.

## Unit tests

С mock provider проверить, что:

* `provider-calls` ожидаемое число;
* `check-calls-in-sampling = 0`;
* `runtime-step-calls > 0`;
* `candidate-count-total` соответствует candidate-policy.

## DoD

* [x] Metrics доступны в `generation-result-metrics`.
* [x] Есть tests для ключевых счетчиков.
* [x] README или docs объясняют counters.
* [x] Hot path regression можно поймать по счетчикам.

---
