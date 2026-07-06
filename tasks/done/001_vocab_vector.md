# Задача 001. Перевести hot-path словарь provider на vector

Исходный номер в `tasks.md`: 001.


## SMART goal

За 1 рабочий день убрать линейный доступ к токенам словаря из hot path генерации: все обращения `token-id -> token string` должны идти через `vector-ref`, а не через `list-ref`.

## Scope

В задаче:

* изменить внутреннее хранение vocab в `provider`;
* добавить функции быстрого доступа:

  ```racket
  provider-vocab-size
  provider-token-ref
  provider-vocab-vector
  ```
* обновить `detokenize`, `provider-next-logit-vector`, `sampling`;
* сохранить совместимость публичного `provider-vocab`, если он уже используется в тестах.

## Out of scope

Не входит:

* переписывание tokenizer на trie;
* оптимизация llama.cpp sidecar;
* изменение DSL API.

## Зачем

Сейчас при full-vocab scan доступ к токену через список может давать квадратичную сложность:

[
\sum_{i=1}^{V} O(i)=O(V^2)
]

Нужно вернуть ожидаемое:

[
O(V)
]

на один проход по словарю.

## Implementation notes

Внутри `provider` хранить vocab как vector.

Допустимо оставить публичный список только как производную форму:

```racket
(define (provider-vocab-list p)
  (vector->list (provider-vocab-vector p)))
```

В hot path использовать только:

```racket
(vector-ref vocab-vec id)
```

## Unit tests

Добавить тесты:

```racket
(check-equal? (provider-vocab-size p) 3)
(check-equal? (provider-token-ref p 0) "yes")
(check-exn exn:fail? (lambda () (provider-token-ref p 10)))
```

## Integration tests

Сгенерировать простой hard guide:

```racket
(seq "Answer: " (select "yes" "no"))
```

Проверить, что результат совпадает с `check`.

## DoD

* [x] В hot path нет `list-ref` по vocab.
* [x] `grep -R "list-ref.*provider-vocab"` ничего не находит.
* [x] Full-vocab scan на mock vocab 50k токенов не растет квадратично.
* [x] Все старые тесты проходят.

---
