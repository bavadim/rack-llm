# Задача 005. Реализовать trie-runtime для finite `select`

Исходный номер в `tasks.md`: 004.


## SMART goal

За 2 рабочих дня заменить исполнение finite `select` через перечисление и `finite-candidates` на trie-runtime, чтобы closed choices работали за (O(k)), где (k) — число допустимых следующих токенов, а не размер словаря.

## Scope

В задаче:

* построить token trie для `select` из finite literal branches;
* поддержать `rank` внутри ветки:

  ```racket
  (select (rank 2 "approve") "reject" "review")
  ```
* `allowed-next-ids` должен возвращать детей текущего trie-node;
* `score` начисляется при завершении ветки.

## Out of scope

Не входит:

* `select` из произвольных regex;
* `select` из `bind`;
* full parser ambiguity.

## Internal API

```racket
build-select-trie : Provider (Listof Guide) -> SelectTrie
select-trie-step  : SelectTrieState TokenId -> SelectTrieState
allowed-next-ids  : SelectTrieState -> (Listof TokenId)
```

## Unit tests

Проверить:

```racket
(select "yes" "no")
```

* в root allowed ids соответствуют первым токенам `yes/no`;
* после `yes` состояние `done`;
* после неизвестного token состояние `dead`.

Проверить ranked branch:

```racket
(select (rank 2 "yes") "no")
```

`yes` имеет guide-score `2`, `no` — `0`.

## Integration tests

На mock provider, где `"maybe"` имеет высокий logit, guide:

```racket
(select "yes" "no")
```

никогда не должен вернуть `"maybe"`.

## DoD

* [x] Finite `select` не вызывает `finite-candidates` в token loop.
* [x] `allowed-next-ids` работает для trie-state.
* [x] Ranked alternatives сохраняют score.
* [x] Wrong token приводит к `dead`.

---
