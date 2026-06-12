# Pencil Puzzle Bench Experiment

This experiment runs Qwen2.5-0.5B-Instruct on the fixed `golden_30` subset
from Pencil Puzzle Bench. It compares ordinary llama.cpp generation with
grammar-constrained `rack-llm` search.

The checked-in dataset contains only puzzle type and URL. Prompt construction,
move validation, and puzzle execution use `ppbench==0.1.0`.

## Setup

From the repository root:

```bash
python -m venv venv
venv/bin/pip install ppbench==0.1.0 requests

make model

.deps/llama.cpp/build/bin/llama-server \
  --model models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  --ctx-size 8192 \
  --parallel 1 \
  --n-gpu-layers 99 \
  --flash-attn on \
  --no-webui
```

## Run

One puzzle:

```bash
venv/bin/python experiments/ppbench/run_baseline.py \
  --index 0 --attempts 10 --show-output

venv/bin/python experiments/ppbench/run_rack_llm.py \
  --index 0 --show-output
```

All 30 puzzles:

```bash
venv/bin/python experiments/ppbench/run_baseline.py \
  --attempts 10 2>&1 | tee ppbench-baseline.log

venv/bin/python experiments/ppbench/run_rack_llm.py \
  2>&1 | tee ppbench-rack-llm.log
```

Use `--timeout SECONDS` for a per-puzzle rack-llm timeout. Without it, the
search is allowed to run until ten complete outputs are found or the stream
ends.

## Grammar

The constrained answer is a Markdown JSON block containing one or more
strings. Each string uses `gen 16`; additional strings are represented with
`at-least-once`.

This grammar guarantees the outer JSON shape, but deliberately does not force
the semantic syntax of a PPBench mouse move. The benchmark checker remains
responsible for deciding whether the moves solve the puzzle.

Recorded findings are in `results/report.md`.
