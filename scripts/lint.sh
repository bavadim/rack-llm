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
"$RACO" make main.rkt grammar.rkt sampler.rkt common-combinators.rkt backends/llama-cpp.rkt backends/openai-responses.rkt

printf 'Checking requires...\n'
check_output=$("$RACO" check-requires $racket_files 2>&1 || true)
filtered_output=$(
  printf '%s\n' "$check_output" \
    | grep -v 'typed-racket/utils/redirect-contract' \
    | grep -v 'typed-racket/private/type-contract' \
    | grep -v 'typed-racket/utils/' \
    | grep -v 'racket/sequence' \
    | grep -v 'racket/contract/parametric' \
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
