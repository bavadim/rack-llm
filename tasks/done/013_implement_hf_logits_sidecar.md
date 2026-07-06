# 013. Реализовать HF logits sidecar для Racket provider

## SMART goal

Реализовать JSON-lines sidecar, который дает Racket-библиотеке доступ к реальному tokenizer и full-vocab logits модели `Qwen/Qwen3.5-4B`. Завершить после задачи 012.

## Зачем это нужно

Для настоящих BPE/SentencePiece моделей нельзя использовать toy longest-string tokenizer по строкам vocab. Paper-grade generation должна использовать тот же tokenizer/model, что и локальная Qwen модель.

## Scope

Создать:

```text
experiments/012_real_model_benchmark/code/hf_logits_sidecar.py
```

Sidecar должен поддерживать JSONL operations:

```text
load
tokenize
detokenize
next_logits
generate_unconstrained
close
```

## Out of scope

- Не запускать IFBench benchmark.
- Не реализовывать Guidance/Outlines.
- Не делать approximate top-k logits для hard generation. Для Racket exact guidance нужен full-vocab vector.

## How

- `load`:
  - загружает tokenizer/model один раз;
  - переводит модель на CUDA;
  - возвращает vocab metadata.
- `tokenize`:
  - принимает `text`;
  - возвращает `ids`.
- `detokenize`:
  - принимает `ids`;
  - возвращает `text`.
- `next_logits`:
  - принимает `prompt`, `prefix`;
  - считает logits следующего токена для `prompt + prefix`;
  - возвращает full-vocab logits, желательно через `logits_b64`.
- `generate_unconstrained`:
  - генерирует vanilla samples для baseline candidate pool;
  - возвращает text, token ids, token logprobs, latency, finish reason.

## Required outputs

```text
experiments/012_real_model_benchmark/code/hf_logits_sidecar.py
experiments/012_real_model_benchmark/results/sidecar_smoke.json
data/012_sidecar_smoke.json
```

## Unit tests

- `test_sidecar_tokenizer_roundtrip`: IFBench prompt survives tokenize/detokenize well enough for generation accounting.
- `test_sidecar_logits_shape`: `next_logits` length equals vocab size.
- `test_sidecar_logits_deterministic`: same prompt/prefix returns same logits within tolerance.
- `test_racket_provider_uses_sidecar_tokenizer`: Racket `tokenize` delegates to sidecar callback.

## DoD

- Sidecar starts from command in `RACK_LLM_LLAMA_SIDECAR`.
- `make-llama-cpp-provider` can call `load/tokenize/detokenize/next_logits`.
- One Racket `sequence-logprob` call succeeds with Qwen sidecar.
- One Racket `generate` call succeeds with Qwen sidecar.
- `make ci` passes.
