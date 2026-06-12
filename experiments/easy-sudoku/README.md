# Easy Sudoku Experiment

This experiment compares ordinary sampling with `rack-llm` search on the same
Qwen3-1.7B model and the same deterministic set of 30 mini-Sudoku 4x4
completion tasks.

The dataset contains ten uniquely solvable tasks at each level: 2, 3, and 4
missing digits. This leaves 16, 64, or 256 possible output arrays.

The model-backed modes use llama.cpp's native Completion endpoint with the
same Qwen ChatML prompt, sampling parameters, disabled thinking, and
temperature `0.8`. The comparison contains:

- `random-unique`: ten unique uniformly random valid arrays;
- `baseline`: ten independent native completions from llama.cpp;
- `baseline-unique`: ordinary resampling until ten unique valid arrays are
  collected, with a cap of 100 requests per puzzle;
- `rack-llm`: up to ten unique grammar-valid arrays from one lazy search.

The `rack-llm` mode requests the top 64 token probabilities at every search
step through the native `rack-llm/backends/llama-cpp` backend.
Baseline generation stops at the first newline so that trailing explanations
do not invalidate an otherwise complete first-line answer.

The grammar is a fixed-length JSON array whose entries are selected from
digits 1 through 4. It intentionally uses no `gen` or `at-least-once`.
The experiment wrapper drops empty llama.cpp token candidates because they do
not advance the grammar and otherwise consume the search depth.

## Setup

From the repository root:

```bash
pip install requests

make deps

# Place the Qwen3-1.7B Q4_K_M GGUF file at:
# models/qwen3-1.7b-q4_k_m.gguf

.deps/llama.cpp/build/bin/llama-server \
  --model models/qwen3-1.7b-q4_k_m.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  --ctx-size 8192 \
  --parallel 1 \
  --n-gpu-layers 99 \
  --flash-attn on \
  --no-webui
```

## Full Comparison

```bash
python experiments/easy-sudoku/run_random_unique.py \
  --attempts 10 \
  --output experiments/easy-sudoku/results/random-unique.jsonl

python experiments/easy-sudoku/run_baseline.py \
  --attempts 10 \
  --output experiments/easy-sudoku/results/baseline.jsonl

python experiments/easy-sudoku/run_baseline_unique.py \
  --attempts 10 --max-requests 100 \
  --output experiments/easy-sudoku/results/baseline-unique.jsonl

python experiments/easy-sudoku/run_rack_llm.py \
  --attempts 10 \
  --output experiments/easy-sudoku/results/rack-llm.jsonl

python experiments/easy-sudoku/analyze.py
```

The generated report is stored in
`experiments/easy-sudoku/results/report.md`.

The comparison is intentionally allowed to produce a negative result. The
success criterion is not that `rack-llm` wins, but that its score can be
separated from random unique enumeration and ordinary unique resampling while
also accounting for runtime and model calls.

The runners report puzzle-level `pass@1` and `pass@10`, both overall and
separately for the 2-, 3-, and 4-blank levels. A puzzle passes if the candidate
exactly matches the missing digits. They also report strict format validity,
errors, elapsed time, and request/oracle cost where applicable.

Run one level separately with `--missing 2`, `--missing 3`, or `--missing 4`.
Use `--limit` and `--index` for short diagnostic runs.

## Dataset

`dataset.jsonl` is checked in for reproducibility. Regenerate it with:

```bash
python experiments/easy-sudoku/generate_dataset.py
```

The generator uses a fixed seed and only applies Sudoku-preserving row,
column, and digit permutations to a valid 4x4 base grid.
