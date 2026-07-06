# 007. Построить clean/noisy soft rules для Soft-IFBench

## SMART goal

Создать `data/soft_ifbench_rules.jsonl`: для каждого soft-supported примера IFBench сгенерировать три набора правил `clean`, `noisy_20`, `noisy_40`. Задача должна быть завершена за 3 рабочих дня после задачи 002. Hard experiments не требуются.

## Зачем это нужно

Soft noisy rules — главный эксперимент метода. Здесь правила имитируют то, как человек пишет простые неполные критерии вокруг примера: обычно точные локально, но с низким покрытием, иногда конфликтующие, иногда ошибочные вне области применимости. Это похоже на weak supervision, только правила используются для управления генерацией, а не только для разметки готовых объектов. Старый черновик уже использовал EM-калибровку эвристик, но там правила были произвольными Python-функциями и применялись к каждому токену; теперь правила должны быть структурными watchers.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

## Scope

Создать модуль:

```text
experiments/ifbench/soft_rules.py
```

Он должен экспортировать:

```python
build_soft_rules(row, noise_level: float) -> list[RuleSpec]
```

Где `noise_level` один из:

```text
0.0
0.2
0.4
```

Сохранить:

```text
data/soft_ifbench_rules.jsonl
```

## Out of scope

- Не запускать LLM.
- Не считать качество watchers на кандидатах.
- Не использовать official verifier при генерации правил.
- Не обучать веса.

## RuleSpec schema

```json
{
  "rule_id": "count_keywords_multiple_keyword1_present",
  "source_instruction_id": "count:keywords_multiple",
  "kind": "rank|ban",
  "weight": 1.0,
  "pattern_type": "regex|literal|structure",
  "pattern": "\bkaleidoscope\b",
  "polarity": "positive|negative",
  "noise": false,
  "noise_type": null,
  "description": "reward if keyword1 appears at least once"
}
```

## Universal rules added to every soft example

Добавить ко всем soft-rule sets:

```text
rank -3 /(?i)\b(as an ai|i cannot|i can't|unable to|sorry)\b/
rank -4 /(?i)(TODO|\[citation needed\]|unknown|null|n\/a)/
ban      /(?i)(private key|api[_ -]?key|secret token)/
```

Universal `ban` нужен только для очевидного hard-veto. Не банить refusal boilerplate: это soft-negative, иначе некоторые сложные prompts будут искусственно уходить в NOT_FOUND.

## Exact soft rules by IFBench constraint

### `count:keywords_multiple`

From `kwargs`: `keyword1..keyword5`.

Clean:

```text
rank +1.0 word-boundary regex for each keyword present at least once
rank +0.5 if keyword with required count > 1 appears at least twice
rank -1.0 if any required keyword absent by end of text
```

Do NOT implement exact required counts as a single hard verifier. That leaks too much of the official task.

Noisy candidates:

```text
wrong inflection: keyword + "s"
substring regex without word boundaries
sign flip for one keyword: rank -1 on a true keyword
wrong keyword sampled from another row in same family
case-sensitive regex bug
```

### `count:conjunctions`

Use coordinating conjunction list:

```text
and, but, for, nor, or, so, yet
```

Clean:

```text
rank +1.0 for each unique conjunction found
rank +2.0 if at least small_n unique conjunctions are found, when small_n is available
rank -1.0 if none of the seven conjunctions are found
```

Noisy:

```text
rank +1.0 for "then" or "however" as if conjunction
case-sensitive conjunction regex
rank -1.0 for "and" to create conflict
wrong threshold small_n + 1
```

### `count:numbers`

Clean:

```text
rank +1.0 if any digit sequence /\b\d+(\.\d+)?\b/ appears
rank +1.0 if at least two digit sequences appear
rank -1.0 if no digit-like token appears
```

Noisy:

```text
rank +1.0 for any spelled number one|two|three even when digit required
rank +1.0 for any year-like 20xx only
rank -1.0 for digits to create conflict
```

### `count:punctuation`

From `kwargs` if punctuation marks are available.

Clean:

```text
rank +1.0 for each required punctuation mark present
rank -1.0 if no punctuation from required set appears
```

Noisy:

```text
wrong punctuation from nearby set
regex without escaping punctuation
sign flip for one punctuation mark
```

### `sentence:keyword`

Clean:

```text
rank +2.0 if keyword appears with word boundaries
rank +0.5 if keyword appears with different case
rank -1.0 if keyword absent
```

Noisy:

```text
wrong keyword from another row
substring without boundary
case-sensitive only
```

### `words:keywords_specific_position`

From `kwargs`: `keyword`, `n`, `m`.

Clean:

```text
rank +2.0 if keyword appears anywhere
rank +1.0 if keyword appears after at least n-3 sentence separators when n > 3
rank +1.0 if keyword appears in a sentence with at least m-5 words when m > 5
rank -1.0 if keyword absent
```

These are approximate by design. Do not implement exact nth sentence and mth word as a verifier in soft mode.

Noisy:

```text
wrong n zone: use n+3 or max(1,n-3)
wrong m zone: use m+5 or max(1,m-5)
wrong keyword
sign flip for keyword present
```

### `words:words_position`

From `kwargs`: `word`, `n`, `m`, or equivalent.

Clean:

```text
rank +2.0 if target word appears anywhere
rank +1.0 if target word appears near approximate target sentence/paragraph zone
rank -1.0 if absent
```

Noisy: same as `words:keywords_specific_position`.

### `format:list`

Clean:

```text
rank +2.0 if at least one bullet line /^\s*[-*+]\s+/m
rank +2.0 if at least one numbered line /^\s*\d+[.)]\s+/m
rank +1.0 if line count >= expected num_bullets when available
rank -2.0 if answer is a single paragraph with no newline
```

Noisy:

```text
rank +1.0 for any hyphen anywhere, not line-start
rank -1.0 for bullet marker to create conflict
wrong expected bullet count num_bullets +/- 1
```

### `format:sub-bullets`

Clean:

```text
rank +2.0 if bullet lines exist
rank +2.0 if indented bullet lines exist /^\s{2,}[-*+]\s+/m
rank -2.0 if no indentation appears
```

Noisy:

```text
wrong indentation threshold
rank +1.0 for any whitespace before line
sign flip on indented bullet
```

### `format:no_bullets_bullets`

Clean:

```text
rank +2.0 if expected mixture of bullet/no-bullet lines is approximated
rank -2.0 if all non-empty lines are bullets
rank -2.0 if no line looks like a bullet
```

Noisy:

```text
rank +1.0 for any list marker anywhere
conflict: rank -1.0 for bullet marker
```

### `format:options`

From `kwargs.options`.

Clean:

```text
rank +3.0 if output contains exactly one option string
rank +1.0 if output starts with one option string
rank -2.0 if output contains more than one option string
rank -2.0 if output contains none
```

Noisy:

```text
wrong option sampled from another row
case-sensitive exact option only
substring option match without boundaries
```

### `format:no_whitespace`

Clean:

```text
rank +3.0 if first line has no whitespace
rank -3.0 if whitespace appears in first 64 chars
```

Noisy:

```text
rank +1.0 if no spaces but tabs ignored
rank -1.0 for punctuation
```

### `format:title_case`

Clean:

```text
rank +2.0 if most words start with uppercase letter
rank +1.0 if first character of each line is uppercase
rank -2.0 if text is mostly lowercase
```

Noisy:

```text
case-sensitive bug with non-ASCII
rank +1.0 if only first word uppercase
```

### `repeat:repeat_simple`, `repeat:repeat_span`, `repeat:repeat_change`

From `kwargs.prompt_to_repeat`, `first_word`, `N` if present.

Clean:

```text
rank +3.0 if repeated span appears verbatim
rank +1.0 if output starts with expected repeated text prefix
rank -2.0 if output includes meta-commentary before repeat
```

For `repeat_change`:

```text
rank +2.0 if first word differs from original when required
rank +1.0 if most of original span is preserved
```

Noisy:

```text
wrong first word
rank +1.0 for partial span only
rank -1.0 for exact repeat to create conflict
```

### `custom:csv_city`

Clean:

```text
rank +2.0 if output has comma-separated rows
rank +2.0 if at least two newline-separated CSV rows
rank +1.0 if city-like capitalized tokens occur
rank -2.0 if Markdown bullets appear instead of CSV
```

Noisy:

```text
wrong delimiter semicolon instead of comma
rank +1.0 for any comma anywhere
```

### `custom:csv_special_character`

Clean:

```text
rank +2.0 if required special character from kwargs appears
rank +1.0 if CSV-like comma rows appear
rank -2.0 if special character absent
```

Noisy:

```text
wrong special character
unescaped regex special character bug
```

### `custom:csv_quotes`

Clean:

```text
rank +2.0 if quoted CSV fields /"[^"]+"/ appear
rank +1.0 if comma-separated quoted rows appear
rank -2.0 if quotes absent
```

Noisy:

```text
rank +1.0 for apostrophes instead of quotes
wrong delimiter
```

### `custom:date_format_list`

Clean:

```text
rank +2.0 if date regex appears, e.g. \b\d{4}-\d{2}-\d{2}\b or required format from kwargs
rank +1.0 if multiple date-like tokens appear
rank -2.0 if no date-like token appears
```

Noisy:

```text
wrong date format DD/MM/YYYY when YYYY-MM-DD expected
rank +1.0 for any 4-digit year
```

## Noise construction

For each clean watcher list:

```text
noise_0   = clean watchers only
noise_20  = clean watchers + noisy watchers equal to 20% of clean count, rounded up
noise_40  = clean watchers + noisy watchers equal to 40% of clean count, rounded up
```

Noisy watchers must be deterministic by `(row.key, noise_level, global_seed)`.

## Unit tests

- `test_rule_schema_valid`: every RuleSpec has required fields.
- `test_noise_ratio`: noisy counts match 20%/40% within ±1 watcher.
- `test_no_verifier_import`: `soft_rules.py` must not import `evaluation_lib` or checker classes.
- `test_keywords_rules`: for first `count:keywords_multiple` row, rules include all five keywords.
- `test_position_rules`: for `words:keywords_specific_position`, rules include keyword and approximate n/m watchers.

## DoD

- `data/soft_ifbench_rules.jsonl` created.
- At least 200 rows have clean soft rules, unless snapshot is smaller; if fewer, write `data/soft_rule_coverage_failures.jsonl`.
- Each row has `clean`, `noisy_20`, `noisy_40` rule sets.
- No official verifier is imported or called.
- Unit tests pass.
