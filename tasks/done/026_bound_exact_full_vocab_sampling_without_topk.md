# 026. Починить exact full-vocab sampling без top-k и зависаний

## SMART goal

Сделать open/soft generation в библиотеке bounded и практически исполнимой без перехода на top-k/shortlist. Семплирование должно оставаться exact over full vocabulary: на каждом generation step рассматриваются все token ids с finite logit. Если полный проход по словарю не укладывается в заданный time budget, библиотека должна вернуть контролируемую ошибку, а не зависнуть.

## Зачем это нужно

Текущий `generate-text` слишком медленный для real soft decoding:

- на каждом шаге строит `adjusted` для всего словаря;
- для каждого token вызывает `guide-step`;
- для `text` path это приводит к `check`/`parse-guide` поверх всего текущего prefix;
- token string берется через list-backed vocab access, что превращает full-vocab loop в крайне дорогой проход;
- `#:deadline-ms` проверяется только на границе шага, поэтому один full-vocab pass может занимать больше бюджета.

Это ломает generation-time soft benchmark: smoke runs завершаются внешним timeout, а не нормальным результатом библиотеки.

## Scope

В scope:

- exact full-vocab sampling в `sampling.rkt`;
- быстрый exact transition path для `(text ...)` watchers;
- deadline checks внутри full-vocab pass;
- публичный статус для budget failure;
- unit/smoke tests через публичный `generate`.

Out of scope:

- top-k, shortlist, nucleus, approximate candidate set;
- перенос benchmark latency/rule-time замеров в библиотеку;
- интеграция полного Experiment 012 benchmark;
- изменение soft-rule dataset lowering.

## Required semantics

Full-vocab generation остается одной формулой:

```text
adjusted_t(v) = logit_t(v) + guide_adjustment_t(v)
```

где `v` пробегает весь vocabulary.

Hard constraints:

```text
guide_adjustment_t(v) = -inf
```

если transition dead.

Soft constraints:

```text
guide_adjustment_t(v) = beta * (Delta guide_score + lambda * Delta potential)
```

если transition live/done.

Если бюджет времени истек во время полного прохода по vocabulary, результат:

```text
status = error-budget
reason = "deadline exhausted during full-vocabulary sampling pass"
```

Не возвращать partial prefix как `found`.

## How

- Заменить текущий full-vector `adjusted` path на streaming Gumbel-Max pass:
  - один проход по logits/vocab;
  - не хранить `adjusted` vector;
  - не хранить `next-states` vector;
  - сразу поддерживать лучший `(token-id, gumbel-score)`;
  - после выбора token пересчитать выбранный transition один раз.
- Убрать дорогой vocab access:
  - один раз на generation attempt сделать `vocab-vec = list->vector(provider-vocab p)`;
  - внутри full-vocab loop использовать `vector-ref`;
  - не вызывать `detokenize` на каждый single-token candidate.
- Добавить быстрый exact path для `text` guide:
  - для `(text ...)` не вызывать `guide-step -> text-runtime-state -> check -> parse-guide` на каждый token;
  - считать score/veto watchers напрямую на `prefix + token`;
  - `rank` дает finite delta;
  - `ban` дает hard-dead transition;
  - финальный `check` использовать только для результата, а не для каждого candidate token.
- Deadline checks:
  - до provider call;
  - после provider call;
  - внутри vocab loop каждые фиксированные N token ids, например 256;
  - при истечении возвращать `error-budget`.
- Не добавлять benchmark metrics в core:
  - не добавлять `rule-time-ms`, `llm-time-ms` или latency breakdown;
  - эксперименты меряют latency снаружи через публичный API.

## Public API changes

- Добавить статус:

```text
error-budget
```

- Обновить predicates/docs так, чтобы `not-found?`/status docs корректно отражали `error-budget`.
- `#:deadline-ms` остается основным публичным механизмом budget control.

## Tests

Unit tests:

- exact small-vocab behavior совпадает с прежней формулой;
- `ban` token никогда не выбирается;
- `rank` меняет выбор при фиксированном seed;
- deadline внутри full-vocab pass возвращает `error-budget`, а не зависает;
- `generate` не требует top-k/approx provider для open/soft generation;
- existing `raco test tests/core-test.rkt` passes.

Smoke test outside core library:

- Qwen/sidecar smoke вызывает только публичный `generate`;
- acceptable outcomes:
  - `found`;
  - `not-found-hard`;
  - `not-found-budget`;
  - `error-budget`;
- unacceptable outcome: external timeout / killed thread due to sampler hang.

## DoD

- Full-vocab open/soft sampling больше не делает O(V^2) vocab access.
- Full-vocab pass проверяет deadline внутри прохода и не зависает дольше заданного бюджета на Racket-side sampling.
- No top-k/shortlist/approximation introduced.
- Core library не расширена benchmark-specific метриками.
- Soft smoke больше не требует внешнего timeout как единственного способа завершить зависший sampler.
- Documentation clearly states: exact full-vocab requires scanning vocabulary; if budget is insufficient, `error-budget` is returned.
