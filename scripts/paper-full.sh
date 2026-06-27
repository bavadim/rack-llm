#!/usr/bin/env sh
set -eu

if [ -z "${RACK_LLM_MODEL:-}" ]; then
  printf '%s\n' "paper-full requires RACK_LLM_MODEL=/path/to/local-model.gguf" >&2
  exit 2
fi

if [ ! -f "$RACK_LLM_MODEL" ]; then
  printf '%s\n' "paper-full RACK_LLM_MODEL does not exist: $RACK_LLM_MODEL" >&2
  exit 2
fi

out="${RACK_LLM_PAPER_FULL_OUT:-runs/paper-full}"
mkdir -p "$out"
cp configs/paper-full.example.json "$out/experiment-config.template.json"

cat > "$out/README.txt" <<EOF
paper-full skeleton prepared.

Model: $RACK_LLM_MODEL
Config template: $out/experiment-config.template.json

Expected outputs after a full local run:
- $out/metrics.csv
- $out/traces.jsonl
- $out/tables/
EOF

printf '%s\n' "$out"
