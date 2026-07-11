#!/usr/bin/env python3
"""Generate real native Qwen candidates for soft-rule auditing."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
DEFAULT_MODEL_PATH = Path("/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
DEFAULT_SEEDS = [0, 1, 2, 3, 4]
POOL_NAME = "012_soft_candidate_pool.jsonl"
RACKET_GENERATOR = EXPERIMENT_DIR / "code" / "racket_soft_candidate_pool.rkt"

sys.path.insert(0, str(EXPERIMENT_DIR / "code"))
from run_hard_runtime_benchmark import official_check, load_registry  # noqa: E402
from racket_env import racket_env  # noqa: E402
from strict_json import strict_json_dumps  # noqa: E402


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_keys(path: Path) -> set[str]:
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(strict_json_dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def selected_rows(input_path: Path, *, keys_file: Path | None, limit_rows: int | None) -> list[dict[str, Any]]:
    rows = read_jsonl(input_path)
    if keys_file is not None:
        keys = read_keys(keys_file)
        rows = [row for row in rows if str(row["key"]) in keys]
    if limit_rows is not None:
        rows = rows[:limit_rows]
    return rows


def label_candidates(candidates: list[dict[str, Any]], source_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    registry = load_registry()
    rows_by_key = {str(row["key"]): row for row in source_rows}
    labeled = []
    for candidate in candidates:
        row = dict(candidate)
        text = str(row.get("text") or "")
        row["official_verifier"] = official_check(rows_by_key[str(row["key"])], text, registry) if text else False
        metadata = dict(row.get("generation_metadata", {}))
        metadata["text_normalized"] = False
        row["generation_metadata"] = metadata
        labeled.append(row)
    return labeled


def run_racket_generator(args: argparse.Namespace, raw_output: Path, input_path: Path) -> None:
    cmd = [
        "racket",
        str(RACKET_GENERATOR),
        "--input",
        str(input_path),
        "--output",
        str(raw_output),
        "--model-path",
        str(args.model_path),
        "--candidates-per-row",
        str(args.candidates_per_row),
        "--max-tokens",
        str(args.max_tokens),
        "--temperature",
        str(args.temperature),
        "--seeds",
        ",".join(str(seed) for seed in args.seeds),
        "--prompt-mode",
        args.prompt_mode,
    ]
    if args.limit_rows is not None:
        cmd.extend(["--limit-rows", str(args.limit_rows)])
    subprocess.run(cmd, cwd=REPO_ROOT, env=racket_env(), check=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--input", type=Path, default=ROOT_DATA_DIR / "soft_ifbench_rules.jsonl")
    parser.add_argument("--candidates-per-row", type=int, default=16)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--seeds", nargs="+", type=int, default=DEFAULT_SEEDS)
    parser.add_argument("--limit-rows", type=int)
    parser.add_argument("--keys-file", type=Path)
    parser.add_argument("--prompt-mode", choices=["original", "strict_final", "strict_chat_no_think"], default="original")
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)

    source_rows = selected_rows(args.input, keys_file=args.keys_file, limit_rows=args.limit_rows)
    source_path = RESULTS_DIR / "012_soft_candidate_pool_input.jsonl"
    write_jsonl(source_path, source_rows)
    raw_output = RESULTS_DIR / "012_soft_candidate_pool.raw.jsonl"
    run_racket_generator(args, raw_output, source_path)
    labeled = label_candidates(read_jsonl(raw_output), source_rows)

    output_paths = [RESULTS_DIR / POOL_NAME]
    if not args.experiment_only:
        output_paths.append(ROOT_DATA_DIR / POOL_NAME)
    for path in output_paths:
        write_jsonl(path, labeled)

    print(
        json.dumps(
            {
                "candidate_rows": len(labeled),
                "input_rows": len(source_rows),
                "backend": "racket_generate_native_llama_cpp_free",
                "outputs": [str(path) for path in output_paths],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
