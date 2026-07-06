# Архитектура `rack-llm` после доработки

Библиотека должна стать компактным рабочим средством, которое можно импортировать и отдельно замерять внешним кодом.

## Главная модель

Центральная абстракция:

```racket
Guide[A]
```

`Guide[A]` генерирует фрагмент строки, возвращает значение типа `A` и имеет log-score. Денотационно:

```text
Guide[A] = WeightedSet[(String, A, LogScore)]
```

`LogScore` живет в шкале:

```text
-inf  = невозможно / hard reject
< 0   = нежелательно
0     = нейтрально
> 0   = предпочтительно
```

Hard-rule является частным случаем:

```text
score(y) = 0     if y ∈ L
score(y) = -inf  otherwise
```

Soft-rule добавляет конечный вес:

```text
score(y) += w if pattern matches
```

## Минимальное ядро

```racket
(pure x)   ; A -> Guide[A]
(bind g f) ; Guide[A] -> (A -> Guide[B]) -> Guide[B]
```

Все остальное должно быть библиотечными комбинаторами поверх этой модели.

## Публичный API v1

```racket
;; closed-world guides
(lit s)
(rx pattern)
(seq g ...)
(select g ...)
(repeat min max g)
(json spec) ; допускается как производная форма, не как ядро

;; open-world segment
(text watch ...)

;; scoring and observers
(rank weight expr)
(ban expr)
(weight #:data samples watch ...)

;; monadic core
(pure x)
(bind g f)

;; execution
(generate provider prompt guide ...)
(generate-stream provider prompt guide ...)
(check guide text)
```

## Контексты

### Closed world

Все обычные `Guide` работают как жесткая грамматика. Если строка не принадлежит языку guide, она невозможна.

```racket
(seq "Answer: " (select "yes" "no"))
```

Допустимы только `Answer: yes` и `Answer: no`.

### Open world

`text` — единственное место открытого мира.

```racket
(text
  (rank 3 (rx #px"\\b(US|EP|WO)\\d+"))
  (rank -5 (rx #px"TODO|\\[citation needed\\]"))
  (ban (rx #px"private key")))
```

Внутри `text` можно сгенерировать любую строку, но `rank` добавляет/вычитает score, а `ban` делает hard reject при совпадении.

## `rank` как отложенная аннотация

`rank` не должен сам открывать мир. Он возвращает отложенную аннотацию:

```racket
(rank w expr) -> Ranked
```

Родительский комбинатор решает, как интерпретировать `Ranked`:

- `seq/select/json` превращают `Ranked` в `Guide` с бонусом закрытой альтернативе;
- `text` превращает `Ranked` в `Watch`, наблюдающий открытый текст.

## Внутренние сущности

Реализация может использовать структуры:

```racket
Guide
Watch
Ranked
Banned
Provider
GenerationResult
CheckResult
```

Публичный API не должен раскрывать лишнюю внутреннюю механику.

## Исполнительная семантика

На каждом шаге декодирования модель дает logits:

```text
l_t(v) = log p(v | prompt, prefix)
```

Guide runtime обновляет состояние по токену:

```text
s' = step(s, v)
```

Если `dead?(s')`, токен маскируется:

```text
l'_t(v) = -inf
```

Иначе:

```text
l'_t(v) = l_t(v) + beta * (Δscore + lambda * Δpotential)
```

После этого выполняется sampling по скорректированным logits.

Иными словами, hard-часть задает support распределения и не зависит от `beta`;
`beta` масштабирует только конечную soft-часть score.

## Найдено / не найдено

Библиотека должна возвращать внутренние статусы:

```text
found
not-found-hard
not-found-budget
not-found-low-score
error-approx-provider
internal-invalid
```

В мягком `text` без return-policy результат обычно всегда может быть найден. `not-found-low-score` появляется только если пользователь явно задал return policy, например `min-guide-score`.
