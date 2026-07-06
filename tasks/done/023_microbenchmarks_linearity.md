# Задача 023. Добавить microbenchmarks для проверки линейности

Исходный номер в `tasks.md`: 023.


## SMART goal

За 1 рабочий день добавить локальные microbenchmarks в `bench/`, чтобы разработчик мог проверить, что full-vocab режим растет линейно по vocab size, а soft text не сканирует весь vocab в `top-k+watch`.

## Scope

Benchmarks:

1. `bench/full_vocab_linear.rkt`

   * vocab sizes: 1k, 5k, 10k, 50k;
   * guide: finite select/trie or simple text;
   * замер времени одного token step.

2. `bench/soft_topk_watch.rkt`

   * fixed vocab 50k;
   * vary K and W;
   * проверить, что время зависит от `K+W`, а не от `V`.

## Out of scope

Не входит:

* IFBench;
* external llama;
* paper tables.

## DoD

* [x] Есть `make bench`.
* [x] Bench выводит CSV.
* [x] Full-vocab step не показывает (O(V^2)).
* [x] top-k+watch step не растет с vocab size при фиксированных K/W.

---
