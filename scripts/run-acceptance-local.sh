#!/usr/bin/env sh
set -eu

LLAMA_SERVER="${LLAMA_SERVER:-.deps/llama.cpp/build/bin/llama-server}"
RACK_LLM_MODEL="${RACK_LLM_MODEL:-models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
RACK_LLM_TEST_PORT="${RACK_LLM_TEST_PORT:-18080}"
RACO="${RACO:-raco}"
LOG_FILE="${RACK_LLM_SERVER_LOG:-llama-server-test.log}"
SERVER_URL="http://127.0.0.1:$RACK_LLM_TEST_PORT"

if [ ! -x "$LLAMA_SERVER" ]; then
  printf 'llama-server is not executable: %s\n' "$LLAMA_SERVER" >&2
  exit 1
fi

if [ ! -s "$RACK_LLM_MODEL" ]; then
  printf 'Model file is missing: %s\n' "$RACK_LLM_MODEL" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  printf 'curl is required for readiness checks.\n' >&2
  exit 1
fi

"$LLAMA_SERVER" \
  --model "$RACK_LLM_MODEL" \
  --host 127.0.0.1 \
  --port "$RACK_LLM_TEST_PORT" \
  --ctx-size 512 \
  --no-webui >"$LOG_FILE" 2>&1 &

server_pid=$!

cleanup() {
  if kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

i=0
while [ "$i" -lt 120 ]; do
  if curl -fsS "$SERVER_URL/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    printf 'llama-server exited before becoming ready. Log follows:\n' >&2
    sed -n '1,160p' "$LOG_FILE" >&2
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$i" -ge 120 ]; then
  printf 'Timed out waiting for llama-server at %s. Log follows:\n' "$SERVER_URL" >&2
  sed -n '1,220p' "$LOG_FILE" >&2
  exit 1
fi

RACK_LLM_ACCEPTANCE=1 \
RACK_LLM_LLAMA_SERVER="$SERVER_URL" \
"$RACO" test tests/acceptance
