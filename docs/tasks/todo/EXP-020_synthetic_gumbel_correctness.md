# EXP-020 — Синтетическая проверка Gumbel-семплера

## SMART goal

За 4 рабочих дня проверить математическую корректность Gumbel-stream на маленьких конечных моделях, где можно явно перечислить все допустимые строки и точное распределение.

## Notebook

`experiments/notebooks/020_synthetic_gumbel_correctness.ipynb`

## Hypothesis

Если token support полный и грамматика конечная, Gumbel-stream должен:
1. выдавать кандидатов без повторов token sequence;
2. совпадать с explicit Gumbel-Top-k на малом дереве;
3. давать эмпирическое распределение, близкое к теоретическому.

## Dataset

Синтетический, генерируется в notebook.

Минимальные грамматики:

1. `choice`: строки из `{"A", "B", "C"}`.
2. `json_bool`: `{"flag": true}` / `{"flag": false}`.
3. `brackets`: короткие сбалансированные скобки глубины ≤ 3.
4. `enum_combo`: `color × shape × size`.

## Scope

- Реализовать mock logit provider с полным словарем.
- Явно перечислить все допустимые строки.
- Рассчитать теоретическое \(p(y)\).
- Запустить Gumbel-stream много раз.
- Сравнить с теорией.

## Out of scope

- Не использовать real LLM.
- Не использовать IFBench.
- Не тестировать качество текста.

## Metrics

\[
D_{TV}=\frac12\sum_y|\hat p(y)-p(y)|
\]

\[
D_{KL}=\sum_y\hat p(y)\log\frac{\hat p(y)}{p(y)}
\]

- `duplicate_rate`
- `top_k_order_match`
- `n_expanded_nodes`
- `frontier_max`

## Experiment plan

1. Для каждой грамматики задать mock probabilities.
2. Явно перечислить допустимые строки.
3. Запустить 10_000 повторов для top-1 sampling.
4. Запустить top-k stream для k=5 и сравнить с explicit Gumbel-Top-k.
5. Повторить в truncated mode `top_K_tokens=[2,3,5]`.

## Expected output format

`distribution_comparison.csv`:

| grammar_id | string | p_true | p_empirical | abs_error |
|---|---|---:|---:|---:|

`summary.csv`:

| grammar_id | mode | tv_distance | kl_divergence | duplicate_rate | top_k_order_match |
|---|---|---:|---:|---:|---:|

## Expected result

- В exact mode `duplicate_rate = 0` для stream top-k.
- TV distance убывает с числом прогонов.
- Truncated mode показывает искажение относительно exact distribution.
- Если `top_K` отсекает допустимые токены, notebook обязан явно показать dropped mass.

## Unit tests

1. Toy grammar из 3 строк: empirical frequencies близки к true probabilities.
2. Stream top-3 не содержит повторов.
3. При fixed seed порядок воспроизводим.
4. Truncated provider логирует dropped mass.

## DoD

- Есть таблицы TV/KL.
- Есть график `tv_vs_samples.png`.
- Есть таблица влияния top-K.
- Результаты можно вставить в раздел Methods/Validation статьи.
