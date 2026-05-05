#!/usr/bin/env sh
set -eu

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-.deps/llama.cpp}"
LLAMA_CPP_REF="${LLAMA_CPP_REF:-master}"
LLAMA_CPP_BUILD_DIR="${LLAMA_CPP_BUILD_DIR:-$LLAMA_CPP_DIR/build}"

jobs() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    printf '2\n'
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 1
  fi
}

require_tool git
require_tool cmake
require_tool cargo

mkdir -p "$(dirname "$LLAMA_CPP_DIR")"

if [ ! -d "$LLAMA_CPP_DIR/.git" ]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
fi

git -C "$LLAMA_CPP_DIR" fetch --depth 1 origin "$LLAMA_CPP_REF"
git -C "$LLAMA_CPP_DIR" checkout FETCH_HEAD

cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_BUILD_DIR" -DLLAMA_LLGUIDANCE=ON
cmake --build "$LLAMA_CPP_BUILD_DIR" -j "$(jobs)"

printf 'llama-server built at %s\n' "$LLAMA_CPP_BUILD_DIR/bin/llama-server"
