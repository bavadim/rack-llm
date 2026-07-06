#!/usr/bin/env python3
"""Generate real Qwen vanilla candidates for soft-rule auditing."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
DEFAULT_MODEL_PATH = Path("/mnt/storage/models/qwen/Qwen3.5-4B")
DEFAULT_SEEDS = [0, 1, 2, 3, 4]
POOL_NAME = "012_soft_candidate_pool.jsonl"

sys.path.insert(0, str(EXPERIMENT_DIR / "code"))
from hf_logits_sidecar import Backend  # noqa: E402
from run_hard_runtime_benchmark import official_check, load_registry  # noqa: E402


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_keys(path: Path) -> set[str]:
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}


def sample_counts(total: int, seeds: list[int]) -> list[tuple[int, int]]:
    base = total // len(seeds)
    extra = total % len(seeds)
    return [(seed, base + (1 if index < extra else 0)) for index, seed in enumerate(seeds)]


def existing_pool(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return read_jsonl(path)


def existing_counts(rows: list[dict[str, Any]], pool_source: str) -> dict[tuple[str, int], int]:
    counts: dict[tuple[str, int], int] = {}
    for row in rows:
        if "seed" not in row:
            continue
        if row.get("pool_source") != pool_source:
            continue
        key = (str(row["key"]), int(row["seed"]))
        counts[key] = counts.get(key, 0) + 1
    return counts


def next_candidate_indices(rows: list[dict[str, Any]]) -> dict[str, int]:
    indices: dict[str, int] = {}
    for row in rows:
        key = str(row["key"])
        indices[key] = max(indices.get(key, 0), int(row.get("candidate_index", -1)) + 1)
    return indices


def write_pool(
    rows: list[dict[str, Any]],
    model_path: Path,
    output_paths: list[Path],
    candidates_per_row: int,
    seeds: list[int],
    max_tokens: int,
    temperature: float,
    top_p: float,
    append_missing: bool = False,
    candidates_per_seed: int | None = None,
    prompt_mode: str = "original",
) -> None:
    registry = load_registry()
    backend = Backend(model_path=model_path)
    backend.load()
    existing = existing_pool(output_paths[-1]) if append_missing else []
    pool_source = pool_source_for(prompt_mode)
    counts = existing_counts(existing, pool_source)
    next_indices = next_candidate_indices(existing)
    handles = []
    try:
        for path in output_paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            handles.append(path.open("a" if append_missing else "w", encoding="utf-8"))
        for row_index, row in enumerate(rows):
            candidate_index = next_indices.get(str(row["key"]), 0) if append_missing else 0
            seed_counts = (
                [(seed, candidates_per_seed) for seed in seeds]
                if candidates_per_seed is not None
                else sample_counts(candidates_per_row, seeds)
            )
            for seed, count in seed_counts:
                if count <= 0:
                    continue
                have = counts.get((str(row["key"]), seed), 0) if append_missing else 0
                if have >= count:
                    continue
                count = count - have
                try:
                    response = backend.generate_unconstrained_batch(
                        {
                            "prompt": prompt_for(row, prompt_mode),
                            "seed": seed,
                            "samples": count,
                            "max_tokens": max_tokens,
                            "temperature": temperature,
                            "top_p": top_p,
                        }
                    )
                    samples = response["samples"]
                except Exception as error:  # noqa: BLE001 - failed generations are benchmark data.
                    samples = [
                        {
                            "sample_index": i,
                            "text": "",
                            "ids": [],
                            "token_logprobs": [],
                            "lm_logprob": None,
                            "latency_ms": 0.0,
                            "generated_tokens": 0,
                            "finish_reason": "error",
                            "error": str(error),
                        }
                        for i in range(count)
                    ]
                for sample in samples:
                    text = str(sample.get("text", ""))
                    generation_status = "GENERATED" if text else "ERROR"
                    payload = {
                        "key": row["key"],
                        "candidate_id": f"{row['key']}:{candidate_index:03d}",
                        "candidate_index": candidate_index,
                        "seed": seed,
                        "batch_sample_index": sample.get("sample_index"),
                        "pool_source": pool_source,
                        "generation_status": generation_status,
                        "failure_reason": sample.get("error", ""),
                        "text": text,
                        "ids": sample.get("ids", []),
                        "token_logprobs": sample.get("token_logprobs", []),
                        "lm_logprob": sample.get("lm_logprob"),
                        "latency_ms": sample.get("latency_ms", 0.0),
                        "generated_tokens": sample.get("generated_tokens", 0),
                        "finish_reason": sample.get("finish_reason", ""),
                        "official_verifier": official_check(row, text, registry) if text else False,
                        "generation_metadata": {
                            "model": str(model_path),
                            "backend": "hf_logits_sidecar.Backend.generate_unconstrained_batch",
                            "temperature": temperature,
                            "top_p": top_p,
                            "max_tokens": max_tokens,
                            "seed": seed,
                            "row_index": row_index,
                            "prompt_mode": prompt_mode,
                        },
                    }
                    for handle in handles:
                        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True))
                        handle.write("\n")
                        handle.flush()
                    candidate_index += 1
    finally:
        for handle in handles:
            handle.close()


def pool_source_for(prompt_mode: str) -> str:
    if prompt_mode == "original":
        return "real_qwen_unconstrained"
    if prompt_mode == "strict_final":
        return "real_qwen_strict_final"
    if prompt_mode == "strict_chat_no_think":
        return "real_qwen_strict_chat_no_think"
    raise ValueError(f"unsupported prompt_mode: {prompt_mode}")


def prompt_for(row: dict[str, Any], prompt_mode: str) -> str:
    if prompt_mode == "original":
        return row["prompt"]
    if prompt_mode == "strict_final":
        return (
            "You are being evaluated by a strict automatic instruction checker. "
            "Follow every constraint exactly. Do not include analysis, hidden reasoning, "
            "or explanations unless the user asked for them. Return only the final answer.\n\n"
            f"{row['prompt']}"
        )
    if prompt_mode == "strict_chat_no_think":
        content = (
            "You are being evaluated by a strict automatic instruction checker. "
            "Follow every constraint exactly. Return only the final answer.\n\n"
            f"{row['prompt']}"
        )
        return f"<|im_start|>user\n{content}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    raise ValueError(f"unsupported prompt_mode: {prompt_mode}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--candidates-per-row", type=int, default=16)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--seeds", nargs="+", type=int, default=DEFAULT_SEEDS)
    parser.add_argument("--candidates-per-seed", type=int)
    parser.add_argument("--append-missing", action="store_true")
    parser.add_argument("--limit-rows", type=int)
    parser.add_argument("--keys-file", type=Path)
    parser.add_argument("--prompt-mode", choices=["original", "strict_final", "strict_chat_no_think"], default="original")
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    rows = read_jsonl(ROOT_DATA_DIR / "soft_ifbench_rules.jsonl")
    if args.keys_file is not None:
        keys = read_keys(args.keys_file)
        rows = [row for row in rows if str(row["key"]) in keys]
    if args.limit_rows is not None:
        rows = rows[: args.limit_rows]
    output_paths = [RESULTS_DIR / POOL_NAME]
    if not args.experiment_only:
        output_paths.append(ROOT_DATA_DIR / POOL_NAME)
    write_pool(
        rows,
        args.model_path,
        output_paths,
        args.candidates_per_row,
        args.seeds,
        args.max_tokens,
        args.temperature,
        args.top_p,
        append_missing=args.append_missing,
        candidates_per_seed=args.candidates_per_seed,
        prompt_mode=args.prompt_mode,
    )
    expected = (
        len(rows) * len(args.seeds) * args.candidates_per_seed
        if args.candidates_per_seed is not None
        else len(rows) * args.candidates_per_row
    )
    print(json.dumps({"rows": len(rows), "target_candidates_for_requested_seeds": expected}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
