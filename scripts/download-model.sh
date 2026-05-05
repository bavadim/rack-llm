#!/usr/bin/env sh
set -eu

RACK_LLM_MODEL="${RACK_LLM_MODEL:-models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
RACK_LLM_MODEL_URL="${RACK_LLM_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf}"

mkdir -p "$(dirname "$RACK_LLM_MODEL")"

if [ -s "$RACK_LLM_MODEL" ]; then
  printf 'Model already exists: %s\n' "$RACK_LLM_MODEL"
  exit 0
fi

if command -v curl >/dev/null 2>&1; then
  curl -L --fail --continue-at - --output "$RACK_LLM_MODEL" "$RACK_LLM_MODEL_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -c -O "$RACK_LLM_MODEL" "$RACK_LLM_MODEL_URL"
else
  printf 'Missing downloader: install curl or wget.\n' >&2
  exit 1
fi

printf 'Model downloaded to %s\n' "$RACK_LLM_MODEL"
