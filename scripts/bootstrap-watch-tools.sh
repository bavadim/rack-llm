#!/usr/bin/env sh
set -eu

RACK_LLM_INSTALL_NOTIFY_DEPS="${RACK_LLM_INSTALL_NOTIFY_DEPS:-1}"

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

case "$(uname -s)" in
  Darwin)
    osascript -e 'return "ok"' >/dev/null
    ;;
  Linux)
    if ! command -v notify-send >/dev/null 2>&1; then
      if [ "$RACK_LLM_INSTALL_NOTIFY_DEPS" = "0" ]; then
        printf '%s\n' \
          'Missing optional tool: notify-send.' \
          'Desktop notifications will be skipped until libnotify is installed.' >&2
      elif command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update
        as_root apt-get install -y libnotify-bin
      elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y libnotify
      elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --noconfirm libnotify
      else
        printf '%s\n' \
          'Missing required tool for desktop notifications: notify-send.' \
          'Install libnotify-bin/libnotify manually, or run with RACK_LLM_INSTALL_NOTIFY_DEPS=0 to skip notifications.' >&2
        exit 1
      fi
    fi
    ;;
  *)
    printf 'Unsupported OS for desktop notifications: %s\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  printf 'Missing required tool: cargo\n' >&2
  exit 1
fi

if ! command -v watchexec >/dev/null 2>&1; then
  cargo install watchexec-cli
fi

printf 'watch dependencies are installed.\n'
