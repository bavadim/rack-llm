# T-014. Добавить режим `truncated-top-k` с явной массой отсечения

**Category:** Provider v2 и full-vocab logits  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P1  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить поддержку top-K provider mode, который явно возвращает только K токенов и логирует покрытую вероятностную массу. Такой режим нужен для абляций, но не должен называться exact.

### В скоупе

- Wrapper `truncate-provider`.
- Вычисление top-K из full logits.
- Поле `truncated-mass` в trace.
- Метка provider mode `truncated-top-k`.

### Не в скоупе

- Адаптивное расширение K.
- Теоретическая коррекция ошибки.

### Публичные интерфейсы

```racket
(: truncate-provider (-> provider Natural provider))
(: provider-exact? (-> provider Boolean))
(: provider-truncated? (-> provider Boolean))
```

### Implementation notes

Если full logits доступны, `truncated-mass` считается как сумма вероятностей отброшенных токенов после softmax. Если provider изначально compatibility-only и не знает полную массу, `truncated-mass = #f`.

### Unit tests

```racket
(define p2 (truncate-provider mock-provider 2))
(define r ((provider-next-logits p2) '() "" st))
(check-equal? (provider-info-mode (provider-info p2)) 'truncated-top-k)
(check-true (fl>= (provider-trace-truncated-mass (logits-result-trace r)) 0.0))
```

### Integration tests

- Synthetic experiment runs in full and truncated modes.
- Output table contains `K` and `truncated_mass_mean`.

### Definition of Done (DoD)

- Truncated mode explicit.
- Exact tests reject truncated provider unless `--allow-truncated`.
- Metrics include discarded mass where available.

---
