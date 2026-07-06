# Задача 017. Исправить logprob: использовать log-softmax, а не raw logits

Исходный номер в `tasks.md`: 014.


## SMART goal

За 1 рабочий день сделать `lm-logprob` математически корректным: score последовательности должен быть суммой log-softmax вероятностей выбранных токенов.

## Scope

В задаче:

* использовать существующий или новый `log-softmax`;
* при выборе token сохранять:

  * raw logit;
  * normalized lm-logprob;
* total-score:
  [
  lm_logprob + \beta \cdot guide_score
  ]

## Out of scope

Не входит:

* calibration score;
* exact normalization в top-k approximate mode.

## Unit tests

На logits:

```racket
#(0.0 0.0)
```

logprob каждого токена должен быть:

[
-\log 2
]

## DoD

* [x] `sequence-logprob` совпадает с ручным расчетом.
* [x] `generation-result-lm-logprob` не равен сумме raw logits.
* [x] Tests для log-softmax проходят.

---
