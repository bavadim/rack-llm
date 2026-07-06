# Реализовать `weight` как EM-взвешенный observer

Status: done

## SMART goal

За 4 рабочих дня реализовать `weight` для калибровки soft-наблюдателей на неразмеченном наборе текстов.

## Dependencies

Зависит от `009_text_and_watch_runtime.md`, `010_contextual_rank.md`, `013_check_on_runtime.md`.

## Scope

- `weight` принимает calibration texts и watchers.
- Watcher должен выдавать сигнал `+1`, `-1`, `0` или matched score orientation.
- Реализовать EM label model с двумя скрытыми классами.
- Оценить likelihood parameters для каждого watcher.
- Вернуть один `Watch`, score которого равен сумме log-likelihood ratios.
- Поддержать smoothing, max-iter, tol.
- Сохранять learned weights/params в структуре для trace.

## Out of scope

- Не реализовывать supervised training.
- Не реализовывать WRENCH/датасеты.
- Не добавлять correlations model. Только независимая EM-модель v1.
- Не вызывать LLM внутри weight.

## Public interfaces / touched interfaces

```racket
(weight #:data samples
        #:max-iter 50
        #:tol 1e-4
        (rank 1  (rx #px"https?://\S+"))
        (rank -1 (rx #px"unknown|null")))
```

## Scientific / design notes

Старый метод использовал EM-калибровку эвристик. В новой библиотеке эта идея остается, но переносится на структурные watchers, чтобы не дергать произвольный код на каждом токене.

## Implementation notes

- Сохранять функциональный минимализм: структуры + чистые функции, без объектных иерархий.
- Не добавлять экспериментальные зависимости.
- Ошибки должны быть явными и локальными: лучше понятный `raise-argument-error`, чем молчаливое “примерно работает”.
- Все новые публичные имена должны быть отражены в документации API.

## Unit tests

- Synthetic dataset: один positive watcher, один negative watcher, один random watcher.
- EM восстанавливает правильный знак positive/negative после ориентации.
- Smoothing предотвращает деление на ноль.
- `weight` с пустым data дает понятную ошибку.

## Integration tests

- Weighted watcher внутри `text` меняет guide-score.
- Trace показывает individual watcher outputs и learned contribution.

## Definition of Done

- [x] `weight` реализован как библиотечный Watch.
- [x] Нет зависимости от экспериментов.
- [x] Есть docs `docs/weight.md` с формулами и ограничениями: EM без anchors/знаков может перевернуть классы.

## Result

Добавлен `weight.rkt`: EM Bernoulli label model строит `watch 'weighted` из
ranked observers. Runtime начисляет learned log-likelihood ratios и пишет
learned params в trace. Добавлена документация `docs/weight.md`.
