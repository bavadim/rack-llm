#!/usr/bin/env sh
set -eu

RACKET="${RACKET:-racket}"

output=$("$RACKET" experiments/synthetic/gumbel-correctness.rkt --seed 42 --runs 100)
printf '%s\n' "$output"

printf '%s\n' "$output" |
  awk -F, '
    NR > 1 {
      if ($4 != 0) {
        printf "duplicate_rate must be 0 for %s, got %s\n", $1, $4 > "/dev/stderr"
        exit 1
      }
      if ($5 > 0.35) {
        printf "TV too high for %s: %s\n", $1, $5 > "/dev/stderr"
        exit 1
      }
    }
  '
