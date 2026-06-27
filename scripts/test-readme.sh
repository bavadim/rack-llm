#!/usr/bin/env sh
set -eu

RACO="${RACO:-raco}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk '
  /^## Minimal Pipeline$/ { armed = 1; next }
  armed && /^```racket$/ { inside = 1; next }
  inside && /^```$/ { found = 1; exit }
  inside { print }
  END { if (!found) exit 42 }
' README.md > "$tmp"

if [ ! -s "$tmp" ]; then
  printf '%s\n' "README runnable Racket block was empty" >&2
  exit 1
fi

"$RACO" test "$tmp"
