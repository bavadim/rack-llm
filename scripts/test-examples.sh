#!/usr/bin/env sh
set -eu

RACKET="${RACKET:-racket}"

for example in examples/*.rkt; do
  "$RACKET" "$example"
done
