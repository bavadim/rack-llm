# Разделить код на минимальные библиотечные модули

Status: done

## SMART goal

За 2 рабочих дня вынести текущий монолитный `main.rkt` в компактную модульную структуру без экспериментальных runner'ов и без лишней архитектуры.

## Dependencies

Нет жестких зависимостей, кроме сохранения архитектурных принципов из `ARCHITECTURE.md`.

## Scope

Создать структуру:

```text
rack-llm/
  core.rkt        ; Guide/Watch/Ranked/result structs, pure/bind
  guides.rkt      ; lit/rx/seq/select/repeat/text/json helpers
  runtime.rkt     ; prefix protocol and check runtime
  sampling.rkt    ; generate/generate-stream
  provider.rkt    ; provider contract and mock provider
  weight.rkt      ; EM weighted observer
  main.rkt        ; re-export public API
  docs/
```

Допускается меньше файлов, если код остается понятным. Больше файлов без причины не надо, мы не строим министерство.

## Out of scope

- Не писать dataset/experiment code.
- Не добавлять CLI.
- Не добавлять notebook support.
- Не переносить старые legacy abstractions в новые модули ради “совместимости”.

## Public interfaces / touched interfaces

`main.rkt` должен только re-export'ить публичный API.

```racket
(require "core.rkt" "guides.rkt" "sampling.rkt" "provider.rkt" "weight.rkt")
(provide ...)
```

## Scientific / design notes

Код должен оставаться функциональным и маленьким: структуры + функции, без объектного диспетчера, registry-manager'ов и прочего ритуального софта.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- `raco test` проходит после переноса.
- Старые unit-тесты, если есть, импортируют только `main.rkt`.
- Проверить, что нет циклических require.

## Integration tests

- Маленький пример `(generate mock prompt (seq ...))` работает через `main.rkt`.
- Маленький пример `(check (text ...) "...")` работает через `main.rkt`.

## Definition of Done

- [x] Код разбит на модули.
- [x] `main.rkt` остается тонким экспортным файлом.
- [x] В дереве библиотеки нет `experiments/`, `notebooks/`, `ifbench/`, `runners/`.
- [x] В README или docs указана новая структура.

## Result

Монолит разделен на `core.rkt`, `guides.rkt`, `runtime.rkt`, `provider.rkt`,
`sampling.rkt`; `main.rkt` теперь только импортирует и переэкспортирует
публичный API. Добавлены тесты на тонкую границу `main.rkt` и отсутствие
экспериментальных директорий.
