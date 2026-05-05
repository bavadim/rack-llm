#!/usr/bin/env sh
set -eu

RACO="${RACO:-raco}"

racket_files=$(
  find . \
    \( -path './.git' -o -path './.deps' -o -path './models' -o -path './compiled' -o -path './*/compiled' \) -prune \
    -o -name '*.rkt' -print \
    | sort
)

printf 'Compiling package modules...\n'
"$RACO" make main.rkt backends/llama-cpp.rkt

printf 'Checking requires...\n'
check_output=$("$RACO" check-requires $racket_files 2>&1 || true)
filtered_output=$(
  printf '%s\n' "$check_output" \
    | grep -v 'typed-racket/utils/redirect-contract' \
    | grep -v '#%contract-defs' \
    | grep -v '^(file ".*"):$' \
    | sed '/^[[:space:]]*$/d' || true
)

if [ -n "$filtered_output" ]; then
  printf '%s\n' "$filtered_output" >&2
  exit 1
fi

printf 'Checking package dependencies...\n'
"$RACO" setup --check-pkg-deps --unused-pkg-deps --no-docs rack-llm

printf 'Lint checks passed.\n'
