# 031. Restore docs/API truth and real e2e API scenarios

Status: done

## Problem

The repository sources of truth drifted after API cleanup and private module
refactors:

- `ARCHITECTURE.md` still described `filter-*` protocol functions as user
  inspectable API.
- `tasks/done/020` claimed standalone examples existed, but the repository now
  uses executable real e2e scenarios as the API safety net.
- Docs did not clearly say that filter, regex, and sampling runtimes are private.

## DoD

- README, `docs/api.md`, `docs/design.md`, and `ARCHITECTURE.md` match the
  current public API.
- E2E scenarios use only the public facade plus `model-qwen.rkt`, and do not
  import `private/*`.
- `make ci` runs the e2e scenarios through `raco test tests`.
- There is no standalone example directory.
- Contract tests still verify that private internals are not exported.

## Result

- README, API docs, design docs, and architecture notes now describe the public
  facade and private runtime boundary.
- Public API scenarios for hard choice, hard regex, text rank/ban, and
  bind/pure composition live in the real Qwen e2e suite.
- Removed standalone example files and their Makefile runner target.
- Verified with `make ci`.
