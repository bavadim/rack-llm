# T-044. Добавить anchors и orientation для Dawid–Skene

**Category:** Rules, Dawid–Skene и acceptance  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P0  
**Timebox:** 4 рабочих дня

### SMART goal

Добавить механизм фиксации ориентации скрытого класса `good/bad`, чтобы DS не переворачивал метки в экспериментах.

### В скоупе

- Anchor rules.
- Dev-set orientation helper.
- Manual orientation config.

### Не в скоупе

- Supervised label model.
- Active learning.

### Публичные интерфейсы

```racket
(struct ds-orientation
  ([mode : (U 'anchor-rule 'dev-gold 'manual)]
   [anchor-rule-id : (Option Symbol)]
   [good-class : DSClass])
  #:transparent)

(: orient-ds-model (-> ds-model ds-orientation (Option GoldLabels) ds-model))
```

### Implementation notes

Варианты:

- `anchor-rule`: high-precision rule, где `accept` должен коррелировать с good.
- `dev-gold`: выбрать ориентацию с лучшим dev AUROC.
- `manual`: пользователь задает, какой класс good.

### Unit tests

```racket
(define flipped (make-flipped-ds-model ...))
(define oriented (orient-ds-model flipped (ds-orientation 'manual #f 1) #f))
(check-true (> (ds-posterior oriented good-obs) (ds-posterior oriented bad-obs)))
```

### Integration tests

- Weak-IFBench dev split uses orientation before test evaluation.

### Definition of Done (DoD)

- Orientation explicitly recorded in model JSON.
- Test split never used for orientation.

---
