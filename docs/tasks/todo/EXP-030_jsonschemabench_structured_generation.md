# EXP-030 — JSONSchemaBench: structured generation и grammar control

## SMART goal

За 5 рабочих дней проверить, насколько библиотека поддерживает JSON Schema и насколько быстро генерирует schema-valid JSON на стандартном benchmark.

## Notebook

`experiments/notebooks/030_jsonschemabench_structured_generation.ipynb`

## Hypothesis

Grammar/token-level control должен давать высокую schema compliance на поддерживаемых JSON Schema и конкурентную скорость после heap + incremental parser.

## Dataset

JSONSchemaBench:
- GitHub: `https://github.com/guidance-ai/jsonschemabench`
- HF: `https://huggingface.co/datasets/epfl-dlab/JSONSchemaBench`
- Содержит около 10 000 real-world JSON schemas.
- Используется для оценки coverage, efficiency и compliance structured output engines.

## Scope

- Загрузить sample/full JSONSchemaBench.
- Для каждой schema попробовать построить grammar.
- Сгенерировать JSON output.
- Проверить output через `jsonschema` validator.
- Сравнить с минимум двумя baselines, если они установлены:
  - Outlines;
  - Guidance;
  - native unconstrained JSON prompt.

## Out of scope

- Не решать downstream task accuracy.
- Не поддерживать весь JSON Schema стандарт, если core-библиотека еще не умеет.
- Не писать новые grammar combinators в notebook.

## Metrics

- `declared_coverage`: доля schemas, которые библиотека заявила как поддержанные.
- `empirical_coverage`: доля schemas, для которых grammar построилась без ошибки.
- `schema_compliance`: доля generated outputs, прошедших `jsonschema.validate`.
- `compile_time_ms`
- `generation_time_ms`
- `tokens_per_second`
- `memory_mb`

## Experiment plan

1. Взять stratified sample:
   - simple schemas;
   - arrays;
   - nested objects;
   - enum;
   - regex/pattern;
   - oneOf/anyOf, если есть.
2. Запустить `rack-llm-json-schema`.
3. Запустить baselines.
4. Сохранить unsupported reasons.

## Expected output format

`schema_results.jsonl`:

```json
{
  "schema_id": "...",
  "schema_features": ["object", "array", "enum"],
  "method": "rack_llm",
  "supported": true,
  "valid_json": true,
  "schema_valid": true,
  "compile_time_ms": 12.3,
  "generation_time_ms": 144.2,
  "error_type": null
}
```

`summary.csv`:

| method | n_schemas | declared_coverage | empirical_coverage | schema_compliance | compile_time_ms_mean | generation_time_ms_mean |
|---|---:|---:|---:|---:|---:|---:|

## Expected result

- На поддерживаемых schemas `schema_compliance` должна быть ~1.0.
- Unsupported schemas должны иметь ясные reasons: `patternProperties`, `recursive_ref`, `oneOf`, etc.
- По speed библиотека должна быть измеримо лучше старой replay/list версии.

## Unit tests

1. Простая object schema генерирует valid JSON.
2. Enum field принимает только разрешенные значения.
3. Required fields всегда присутствуют.
4. Unsupported feature возвращает controlled error, не stack trace.

## DoD

- Есть summary table для статьи.
- Есть breakdown по schema features.
- Все unsupported cases сохранены в CSV.
