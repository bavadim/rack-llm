# EXP-021 — Микробенчмарк сложности: очередь, parser, frontier

## SMART goal

За 3 рабочих дня измерить вычислительную сложность ключевых частей алгоритма: agenda/priority queue, incremental parser, frontier growth.

## Notebook

`experiments/notebooks/021_complexity_microbenchmarks.ipynb`

## Hypothesis

Heap-agenda и incremental parser должны устранить лишнюю линейность текущей реализации:
- list-agenda деградирует при росте frontier \(F\);
- heap-agenda масштабируется как \(O(\log F)\);
- incremental parser быстрее replay-parser на длинных outputs.

## Dataset

Синтетические grammar workloads:

1. `wide_enum`: большое число альтернатив.
2. `deep_json`: вложенный JSON.
3. `repeat_list`: список из N элементов.
4. `mixed_schema`: поля разных типов.

## Scope

Измерить:

- `agenda_push_ms`
- `agenda_pop_ms`
- `parser_advance_ms`
- `n_expanded_nodes`
- `frontier_max`
- `memory_mb`

Для реализаций:

- `list_agenda`
- `binary_heap_agenda`
- `pairing_heap_agenda`, если есть
- `replay_parser`
- `incremental_parser`

## Out of scope

- Не запускать real LLM.
- Не мерить качество генерации.
- Не делать оптимизации прямо в notebook.

## Experiment plan

1. Сгенерировать synthetic priorities: \(F = 10^2, 10^3, 10^4, 10^5\).
2. Измерить push/pop для agenda.
3. Сгенерировать строки длиной \(L = 50, 100, 500, 1000\).
4. Измерить parser advance.
5. Запустить synthetic Gumbel expansion на grammar workloads.
6. Сохранить графики log-log.

## Expected output format

`summary.csv`:

| component | implementation | workload | size | mean_ms | p95_ms | memory_mb |
|---|---|---|---:|---:|---:|---:|

Figures:

```text
figures/agenda_push_pop_loglog.png
figures/parser_advance_vs_length.png
figures/frontier_size_vs_time.png
```

## Expected result

- `binary_heap_agenda` быстрее list при \(F\ge10^4\).
- `incremental_parser` быстрее replay-parser минимум в 3 раза на \(L\ge500\).
- В статье использовать формулу:

\[
T=O(NC_{LLM}+EC_G+(N+E)\log F+RC_H)
\]

## Unit tests

1. Все agenda implementations возвращают элементы в одинаковом порядке priority.
2. Parser implementations одинаково принимают/отклоняют строки.
3. Benchmark сохраняет raw timings.

## DoD

- Есть таблица и 3 графика.
- В notebook явно написано, какая реализация используется в дальнейших экспериментах.
- Нет claims про \(O(1)\) pop-max для произвольных float priorities. Физику и структуры данных пока не отменили.
