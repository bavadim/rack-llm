# T-078. Написать минимальный migration guide

**Category:** Документация, примеры и релиз  
**Library style:** функциональный минимализм: чистые функции, явное состояние, IO только на границах, маленький composable API.

**Priority:** P2  
**Timebox:** 2 рабочих дня

### SMART goal

Написать `docs/migration-token-oracle-to-provider-v2.md`, объясняющий переход от старого `TokenOracle` к `Provider v2`.

### В скоупе

- Old API example.
- New API example.
- Compatibility adapter.
- Exact vs truncated warning.

### Не в скоупе

- Автоматический codemod.

### Unit tests

Не применимо.

### Integration tests

Не применимо.

### Definition of Done (DoD)

- Migration guide есть.
- Пользователь старого API понимает, что поменять.
