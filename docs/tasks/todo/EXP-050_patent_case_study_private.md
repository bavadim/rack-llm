# EXP-050 — Промышленный case study патентных отчетов

## SMART goal

За 4–6 рабочих дней подготовить notebook для анализа production-трасс патентных отчетов: показать прикладную полезность, не выдавая ее за публичный SOTA benchmark.

## Notebook

`experiments/notebooks/050_patent_case_study_private.ipynb`

## Hypothesis

В промышленной задаче метод снижает число неподтвержденных выводов, дубликатов и ручных правок, потому что отчет строится из проверенной цепочки: тема → свойства → документы → матрица подтверждений → отчет.

## Input data

Private production traces, если доступны:

```text
experiments/data/private/patent_reports/
  report_id/
    topic.json
    properties.json
    search_plan.json
    documents.jsonl
    evidence_matrix.json
    report.md
    expert_review.json
```

Пример структуры отчета есть в текущих материалах: отчет содержит постановку задачи, источниковую базу, методологию, карту кластеров, количественные окна, противоречия, лабораторные проверки и короткие выводы.

## Scope

- Проанализировать минимум 30 отчетов, если доступны.
- Считать качество внутренних артефактов:
  - доля ячеек матрицы с цитатой;
  - доля документов с `U(d)>0`;
  - число GAP по свойствам;
  - число дубликатов патентных семейств;
  - число экспертных правок.
- Сравнить до/после включения rules/resampling, если есть historical runs.

## Out of scope

- Не публиковать приватные тексты и коммерческие темы.
- Не делать юридическую оценку патентоспособности.
- Не сравнивать с публичным leaderboard.

## Metrics

- `citation_coverage`: доля positive/partial cells with quote+source.
- `document_noise_rate`: доля документов с \(U(d)=0\).
- `gap_rate`: доля свойств без подтверждений.
- `duplicate_family_rate`.
- `expert_acceptance_rate`.
- `manual_corrections_per_report`.
- `time_to_report_hours`.

## Expected output format

`case_study_summary.csv`:

| report_id_hash | n_properties | n_documents | citation_coverage | document_noise_rate | gap_rate | expert_acceptance_rate | manual_corrections |
|---|---:|---:|---:|---:|---:|---:|---:|

`figures/`:

```text
citation_coverage_distribution.png
manual_corrections_distribution.png
time_to_report_boxplot.png
```

## Expected result

- Показать, что система построила 30+ отчетов.
- Большинство positive/partial связей имеют цитаты/ссылки.
- Отчеты пригодны для экспертной доработки.
- Этот блок идет в статью как industrial validation, не как основной benchmark.

## Unit tests

1. Loader читает один fake report.
2. `citation_coverage` корректно считает только positive/partial cells.
3. `document_noise_rate` корректно считает документы с \(U=0\).
4. Hashing скрывает реальные report_id.

## DoD

- Нет приватных данных в git.
- Все идентификаторы захешированы.
- Есть агрегированные таблицы и графики.
- В notebook явно написано: `private case study, not public SOTA comparison`.
