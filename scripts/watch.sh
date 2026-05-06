#!/usr/bin/env sh
set -eu

WATCH_TARGET="${WATCH_TARGET:-test}"

notify() {
  title="$1"
  message="$2"

  case "$(uname -s)" in
    Darwin)
      osascript -e "display notification \"${message}\" with title \"${title}\"" >/dev/null
      ;;
    Linux)
      if command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$message" >/dev/null
      fi
      ;;
  esac
}

run_once() {
  printf '%s\n' "Running make ${WATCH_TARGET}..."
  if make "$WATCH_TARGET"; then
    notify "rack-llm" "make ${WATCH_TARGET} passed"
    printf '%s\n' "make ${WATCH_TARGET} passed"
  else
    status=$?
    notify "rack-llm" "make ${WATCH_TARGET} failed"
    printf '%s\n' "make ${WATCH_TARGET} failed"
    return "$status"
  fi
}

if [ "${1:-}" = "--run-once" ]; then
  run_once
  exit $?
fi

printf '%s\n' "Watching Racket and shell sources. Target: make ${WATCH_TARGET}"
printf '%s\n' "Override with: make watch WATCH_TARGET=ci"

run_once || true

exec watchexec \
  --clear \
  --watch . \
  --filter '*.rkt' \
  --filter '*.sh' \
  --filter 'Makefile' \
  --ignore .git \
  --ignore compiled \
  --ignore .deps \
  --ignore models \
  --ignore llama-server-test.log \
  -- "$0" --run-once
