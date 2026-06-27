# EXP-040 — BFCL: function calling как end-to-end structured/action generation

## SMART goal

За 5–7 рабочих дней провести дополнительный эксперимент на BFCL: показать, что grammar + weak rules + resampling улучшают корректность вызовов функций относительно простых baseline.

## Notebook

`experiments/notebooks/040_bfcl_function_calling_weak_constraints.ipynb`

## Hypothesis

В function calling грамматика убирает format errors, а weak rules помогают выбрать семантически более правильный function call. Gumbel/DS должны улучшить execution/AST accuracy при фиксированном бюджете кандидатов.

## Dataset

BFCL:
- GitHub: `https://github.com/ShishirPatil/gorilla/tree/main/berkeley-function-call-leaderboard`
- Package: `bfcl-eval`
- Paper: Berkeley Function Calling Leaderboard, ICML 2025.
- BFCL оценивает function calling в разных сценариях, включая serial/parallel calls, AST-based evaluation и executable tests.

## Scope

- Подключить BFCL evaluator.
- Выбрать subset:
  - simple;
  - multiple;
  - parallel;
  - irrelevance/no-call.
- Генерировать function call JSON.
- Применить grammar:
  - valid JSON;
  - only known function names;
  - required fields;
  - argument types;
  - enum values.
- Применить weak rules:
  - selected function name overlaps with intent keywords;
  - required arguments present;
  - no extra unknown arguments;
  - no function call for irrelevant prompt;
  - argument value copied/normalized from prompt when applicable.

## Out of scope

- Не участвовать в live leaderboard.
- Не оптимизировать под каждую категорию BFCL.
- Не решать multi-turn memory categories, если core-библиотека не готова.

## Methods

- `base_pass1`
- `grammar_only`
- `independent_majority_B`
- `independent_ds_B`
- `gumbel_majority_B`
- `gumbel_ds_B`
- `bfcl_oracle_upper_bound`

## Metrics

Официальные BFCL:

- AST accuracy
- execution accuracy
- relevance/no-call accuracy
- hallucination rate

Наши дополнительные:

- invalid JSON rate
- accepted rank
- duplicate rate
- latency
- candidate budget used

## Expected output format

`bfcl_results.jsonl`:

```json
{
  "task_id": "...",
  "category": "simple",
  "method": "gumbel_ds_B",
  "budget": 8,
  "selected_call": {"name": "...", "arguments": {}},
  "ast_correct": true,
  "execution_correct": true,
  "invalid_json": false,
  "hallucinated_function": false
}
```

`summary.csv`:

| method | category | budget | ast_accuracy | execution_accuracy | relevance_accuracy | hallucination_rate | invalid_json_rate |
|---|---|---:|---:|---:|---:|---:|---:|

## Expected result

- `grammar_only` снижает invalid JSON почти до 0.
- `gumbel_ds_B` улучшает AST/execution accuracy относительно grammar-only и independent majority.
- В irrelevance/no-call категории weak rules должны снижать hallucinated function calls.

## Unit tests

1. BFCL evaluator вызывается на одной known sample.
2. Grammar запрещает неизвестное имя функции.
3. Weak rule `required_args_present` reject при отсутствии обязательного argument.
4. No-call rule reject при вызове функции на irrelevant prompt.

## DoD

- Есть BFCL subset results.
- Есть comparison table.
- В metadata зафиксирован commit/version BFCL.
