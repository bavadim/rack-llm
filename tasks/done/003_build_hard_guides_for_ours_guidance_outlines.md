# 003. Реализовать hard-грамматики для нашего DSL, Guidance и Outlines

## SMART goal

Для всех `hard_supported=true` из `data/ifbench_constraint_map.json` реализовать генераторы закрытых правил для трех систем: наша библиотека, Microsoft Guidance, Outlines. Задача должна быть завершена за 3 рабочих дня после задачи 002.

## Зачем это нужно

Первые два эксперимента проверяют жесткий режим: решение должно либо найти строку, проходящую official verifier, либо честно вернуть `NOT_FOUND`. В hard-режиме не должно быть `FOUND_WRONG`, если конвертер грамматики верен. Guidance/Outlines нужны как baseline именно для этой части, потому что они решают задачу жесткой controlled generation.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

Дополнительно:

- Guidance: https://github.com/guidance-ai/guidance
- Outlines: https://github.com/dottxt-ai/outlines

## Scope

Создать модуль:

```text
experiments/ifbench/hard_guides.py
```

Он должен экспортировать:

```python
build_ours_hard_guide(row) -> OursGuide | Unsupported
build_guidance_hard_grammar(row) -> GuidanceSpec | Unsupported
build_outlines_hard_grammar(row) -> OutlinesSpec | Unsupported
```

## Out of scope

- Не запускать модель.
- Не считать метрики.
- Не строить soft/noisy rules.
- Не реализовывать новые возможности библиотеки.

## Required hard builders

### `format:options`

- Наша библиотека: `select(lit(option_1), lit(option_2), ...)`.
- Guidance: `select(options)`.
- Outlines: regex или choice из options.
- Допустимы только сами options. Объяснение после option запрещено.

### `format:no_whitespace`

- Regex: `^\S+$`.
- Max length брать из общего experiment config, если IFBench не задает длину.

### `format:title_case`

- Regex/monitor для Title Case на уровне слов.
- Если реализация Title Case в official verifier сложнее, пометить family как `requires_agreement_validation`.

### `format:newline`

- Строковая структура с требуемыми newline separators.
- Если количество строк задано в `kwargs`, использовать его.

### `format:list`, `format:sub-bullets`, `format:no_bullets_bullets`

- Генерировать список с допустимыми bullet/numbered markers.
- Если точная структура не восстанавливается из `kwargs`, builder возвращает `Unsupported` для данного row.

### `format:line_indent`

- Генерировать строки с требуемым indentation pattern.
- Если pattern не восстанавливается из `kwargs`, `Unsupported`.

### `format:parentheses`, `format:quotes`, `format:quote_unquote`

- Использовать bounded regex / small grammar.
- Не строить неограниченную nested grammar. Если глубина не задана, ограничить экспериментальным максимумом и записать это в metadata.

### `custom:csv_city`, `custom:csv_special_character`, `custom:csv_quotes`

- Генерировать CSV-подобный формат.
- Минимум: правильный delimiter, expected rows/columns if available, quoting rule.
- Если city list или exact content hidden in verifier, builder должен быть `Unsupported`, а не притворяться волшебником.

### `custom:date_format_list`

- Генерировать список дат в требуемом формате.
- Использовать regex для дат; не проверять календарную валидность, если official verifier этого не требует.

### `repeat:repeat_simple`, `repeat:repeat_span`, `repeat:repeat_change`

- Использовать `prompt_to_repeat`, `first_word`, `N`, если они есть в `kwargs`.
- Если повторяемый текст не извлекается, `Unsupported`.

## Output schema

Каждый builder должен возвращать объект с metadata:

```json
{
  "supported": true,
  "instruction_ids": ["format:options"],
  "guide_source": "...",
  "notes": "...",
  "expected_exactness": "exact|near_exact|bounded"
}
```

## Unit tests

- Для каждого hard builder создать минимум 3 synthetic valid strings и 3 invalid strings.
- `build_*` не должен падать на unsupported rows; он возвращает `Unsupported(reason)`.
- Для `format:options`: строки вне options должны reject.
- Для `repeat:*`: output должен содержать повторяемый span/измененный span по kwargs.

## DoD

- `hard_guides.py` создан.
- Все required builders реализованы или явно возвращают `Unsupported` с причиной.
- Есть unit tests для каждого supported builder.
- Guidance/Outlines specs строятся для тех же rows, что и ours, иначе row исключается из hard-comparison subset.
