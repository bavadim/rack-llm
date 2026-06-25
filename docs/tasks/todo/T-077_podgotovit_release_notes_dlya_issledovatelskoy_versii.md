# T-077. Подготовить release notes для исследовательской версии

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P2  
**Timebox:** 2 рабочих дня

### SMART goal

Подготовить `CHANGELOG.md` и release notes для версии `v0.2-research`, где перечислены provider v2, Gumbel stream, rules, Dawid–Skene, Weak-IFBench runner.

### В скоупе

- Changelog entry.
- Known limitations.
- Migration notes from old `TokenOracle`.

### Не в скоупе

- Actual GitHub release.
- Package publish.

### Публичные интерфейсы

Файл:

```text
CHANGELOG.md
```

### Unit tests

Не применимо.

### Integration tests

Не применимо.

### Definition of Done (DoD)

- Changelog exists.
- Limitations include top-K/truncated caveat and DS independence assumption.

---
