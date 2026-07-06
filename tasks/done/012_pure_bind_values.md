# Реализовать `pure/bind` как функциональное связывание результатов

Status: done

## SMART goal

За 3 рабочих дня сделать монадическое связывание результатов генерации без `cap/calc/emit` и без env-map в публичном API.

## Dependencies

Зависит от `007_prefix_runtime_protocol.md`; желательно после `008_closed_guides_runtime.md`.

## Scope

- `pure` порождает пустую строку и значение.
- `bind` завершает первый guide, берет его value и строит следующий guide через функцию.
- `seq` может оставаться сахаром для независимых guide.
- Значение guide должно быть доступно в continuation.
- `bind` должен работать сегментно: следующий guide строится после завершения предыдущего, а не на каждом токене.

## Out of scope

- Не добавлять публичные `cap`, `calc`, `emit`.
- Не реализовывать полноценный Prolog/backtracking по произвольным предикатам.
- Не добавлять DSL recursion.

## Public interfaces / touched interfaces

```racket
(bind (rx #px"[1-9][0-9]?")
  (lambda (a)
    (seq (lit " sum=")
         (lit (number->string (+ (string->number a) 1))))))
```

## Scientific / design notes

Связывание через `bind` дает динамические шаблоны: результат одной генерации параметризует следующий фильтр. Это научно чище, чем env-map/capture, и ближе к `Guide[A]` как монадической алгебре.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `pure` ничего не добавляет к строке и возвращает value.
- `bind` склеивает строки и складывает score.
- Continuation получает сгенерированное значение.
- `bind` с finite first guide работает в `finite-candidates`.

## Integration tests

- Пример “сгенерировать 2 числа, посчитать сумму, продолжить text” работает.
- Динамический regex на основе предыдущего результата работает: generated id потом ранжируется в text.

## Definition of Done

- [x] `pure/bind` реализованы в runtime и check.
- [x] Не используются публичные env maps.
- [x] Документировано, что произвольная рекурсия не часть DSL; обычные Racket-функции могут строить конечный Guide.

## Result

Добавлены тесты на `pure`, `bind`, continuation value, finite generation с
`bind` и динамический regex на основе предыдущего результата. API doc теперь
объясняет, что `bind` заменяет capture/env-map подход.
