# Добавить `generate-stream`, samples и keep-best

Status: done

## SMART goal

За 3 рабочих дня сделать поток кандидатов и режим best-of-N внутри библиотеки без экспериментальных зависимостей.

## Dependencies

Зависит от `014_sampling_engine.md`.

## Scope

- Реализовать `generate-stream`, возвращающий lazy sequence/stream кандидатов.
- Реализовать `generate #:samples N #:keep-best? #t`.
- При keep-best хранить только текущий и лучший candidate.
- Каждый candidate должен иметь lm-logprob, guide-score, total-score, status, trace.
- Поддержать `#:unique 'none`, `#:unique '(cache N)` как библиотечные режимы. `exact` можно зарезервировать, но не реализовывать в v1.

## Out of scope

- Не реализовывать IFBench Oracle@N.
- Не реализовывать exact no-replacement sampling.
- Не писать CSV/JSONL exporters для экспериментов.

## Public interfaces / touched interfaces

```racket
(generate-stream provider prompt guide #:seed 1 ...)
(generate provider prompt guide #:samples 8 #:keep-best? #t)
```

## Scientific / design notes

Для soft rules библиотека должна уметь выдать несколько попыток и выбрать лучшую по внутреннему score. Это не экспериментальный runner, а базовая библиотечная функция.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `generate-stream` возвращает N кандидатов при `(take N ...)`.
- `keep-best?` выбирает max total-score.
- `unique none` допускает повторы.
- `unique cache` не возвращает точный повтор в пределах cache на mock сценарии.

## Integration tests

- Soft text guide с samples=8 возвращает лучший из 8.
- Hard guide при невозможности всех попыток возвращает not-found статус с attempts=N.

## Definition of Done

- [x] `generate-stream` реализован.
- [x] `generate #:samples` использует stream, не дублирует логику.
- [x] Память best-of не растет по N, кроме optional cache.

## Result

Добавлен lazy `generate-stream`. `generate` теперь потребляет stream,
поддерживает `#:samples`, `#:keep-best?`, `#:unique 'none` и `#:unique '(cache
N)`. Добавлены тесты stream/take, best-of, duplicates и cache uniqueness.
