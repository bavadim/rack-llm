# 002. Классифицировать IFBench constraints на hard и soft поднаборы

## SMART goal

Создать файл классификации IFBench instruction ids по экспериментальным поднаборам: `hard_supported`, `soft_supported`, `excluded`. Задача должна быть завершена за 1 рабочий день после задачи 001.

## Зачем это нужно

Hard-сравнение с Guidance/Outlines имеет смысл только для constraints, которые честно переводятся в закрытые грамматики. Soft/noisy experiment, наоборот, должен использовать constraints, где можно написать простые неполные правила. Не смешиваем эти режимы, иначе получится сравнение яблок с гайками, а это уже стандартная академическая кулинария.

## Ссылки

- IFBench GitHub: https://github.com/allenai/IFBench
- IFBench raw test data: https://raw.githubusercontent.com/allenai/IFBench/main/data/IFBench_test.jsonl
- IFBench instruction registry: https://raw.githubusercontent.com/allenai/IFBench/main/instructions_registry.py
- IFBench evaluation library: https://raw.githubusercontent.com/allenai/IFBench/main/evaluation_lib.py
- Hugging Face dataset card: https://huggingface.co/datasets/allenai/IFBench_test

## Scope

- Прочитать `data/ifbench_snapshot.jsonl`.
- Построить список всех `instruction_id`.
- Для каждого `instruction_id` назначить:
  - `family`
  - `hard_supported: true/false`
  - `soft_supported: true/false`
  - `reason`
  - `builder_task`: имя функции, которую надо будет реализовать в задачах 003/007.
- Сохранить `data/ifbench_constraint_map.json`.

## Out of scope

- Не писать грамматики.
- Не писать soft watchers.
- Не запускать модель.
- Не запускать official verifier.

## Hard-supported instruction ids

Включить в hard-поднабор только эти families, если они есть в snapshot:

```text
format:options
format:output_template
format:no_whitespace
format:title_case
format:newline
format:list
format:sub-bullets
format:no_bullets_bullets
format:line_indent
format:quote_unquote
format:parentheses
format:quotes
custom:csv_city
custom:csv_special_character
custom:csv_quotes
custom:date_format_list
repeat:repeat_simple
repeat:repeat_span
repeat:repeat_change
```

Помечать `hard_supported=false`, если конкретный пример требует внешней семантики, слишком большого конечного автомата или не имеет однозначной грамматики.

## Soft-supported instruction ids

Включить в soft/noisy поднабор эти families:

```text
count:keywords_multiple
count:conjunctions
count:numbers
count:punctuation
sentence:keyword
words:keywords_specific_position
words:words_position
format:list
format:sub-bullets
format:no_bullets_bullets
format:options
format:no_whitespace
format:title_case
repeat:repeat_simple
repeat:repeat_span
repeat:repeat_change
custom:csv_city
custom:csv_special_character
custom:csv_quotes
custom:date_format_list
```

Допускается добавить другие ids из registry, но только с коротким `reason`, почему можно построить простые неполные правила.

## Excluded examples

Исключать из обоих поднаборов, если:

- constraint требует семантической оценки, не выражаемой регулярками/структурными watchers;
- constraint требует языкового анализа, который не входит в DSL v1, например syllables/Japanese/POS, если нет готового простого checker;
- hard-грамматика будет практически равна official verifier и при этом не реализуема в Guidance/Outlines простыми средствами;
- пример содержит несколько instruction ids, из которых хотя бы один не поддержан выбранным режимом.

## Required schema: `ifbench_constraint_map.json`

```json
{
  "format:options": {
    "family": "format",
    "hard_supported": true,
    "soft_supported": true,
    "hard_builder": "build_hard_options",
    "soft_builder": "build_soft_options",
    "reason": "fixed choice; can be expressed as select"
  }
}
```

## Unit tests

- `test_all_ids_classified`: каждый id из snapshot есть в map.
- `test_no_empty_reason`: у каждого id непустой `reason`.
- `test_hard_builders_named`: у `hard_supported=true` указан `hard_builder`.
- `test_soft_builders_named`: у `soft_supported=true` указан `soft_builder`.

## DoD

- `data/ifbench_constraint_map.json` создан.
- Все ids классифицированы.
- Hard/soft поднаборы непустые.
- Все unit tests проходят.
