#!/usr/bin/env python3
"""Normalize real hard-runtime outputs into the Experiment 005 schema.

This experiment is intentionally fail-closed: it no longer creates candidate
answers from hard-guide specs or regex witnesses. Generated hard rows come from
Experiment 012 real runtime artifacts. Constraints that the current real
runtime cannot execute are recorded as NOT_FOUND for every configured seed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import statistics
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

CONFIG_PATH = EXPERIMENT_DIR / "config.json"
HARD_SUBSET_PATH = ROOT_DATA_DIR / "hard_ifbench_subset.jsonl"
REAL_HARD_RAW = ROOT_DATA_DIR / "012_hard_real_raw.jsonl"
REAL_HARD_FAILURES = ROOT_DATA_DIR / "012_hard_runtime_failures.jsonl"

RAW_NAME = "005_hard_solve_raw.jsonl"
SUMMARY_NAME = "005_hard_solve_summary.csv"
WRONG_FAILURES_NAME = "005_hard_wrong_failures.jsonl"

HARD_METHODS = ["ours_hard", "guidance_hard", "outlines_hard"]
POSTHOC_METHODS = ["vanilla_nucleus_posthoc", "repair_loop_posthoc"]
METHODS = HARD_METHODS + POSTHOC_METHODS


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise SystemExit(f"required input is missing: {path}")
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def text_hash(text: str | None) -> str | None:
    if text is None:
        return None
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalize_outcome(outcome: str) -> str:
    if outcome in {"SOLVED", "FOUND_OK"}:
        return "FOUND_OK"
    if outcome in {"WRONG", "FOUND_WRONG"}:
        return "FOUND_WRONG"
    return "NOT_FOUND"


def runtime_row(
    source: dict[str, Any],
    input_row: dict[str, Any],
    method: str,
    seed: int,
    attempts: int,
) -> dict[str, Any]:
    text = source.get("text") or ""
    outcome = normalize_outcome(str(source.get("outcome", "NOT_FOUND")))
    return {
        "method": method,
        "example_id": input_row["key"],
        "instruction_id_list": input_row["instruction_id_list"],
        "seed": seed,
        "outcome": outcome,
        "official_ok": bool(source.get("official_verifier")) and outcome == "FOUND_OK",
        "latency_ms": float(source.get("latency_ms") or 0.0),
        "generated_tokens": int(source.get("generated_tokens") or 0),
        "attempts": attempts,
        "text_hash": text_hash(text) if text else None,
        "text": text,
        "reason": source.get("failure_reason") or source.get("reason") or "",
        "source": "real_runtime_012",
    }


def not_found_row(
    input_row: dict[str, Any],
    method: str,
    seed: int,
    attempts: int,
    reason: str,
    source: str,
) -> dict[str, Any]:
    return {
        "method": method,
        "example_id": input_row["key"],
        "instruction_id_list": input_row["instruction_id_list"],
        "seed": seed,
        "outcome": "NOT_FOUND",
        "official_ok": False,
        "latency_ms": 0.0,
        "generated_tokens": 0,
        "attempts": attempts,
        "text_hash": None,
        "text": "",
        "reason": reason,
        "source": source,
    }


def build_raw(rows: list[dict[str, Any]], config: dict[str, Any]) -> list[dict[str, Any]]:
    real_rows = read_jsonl(REAL_HARD_RAW)
    failure_rows = read_jsonl(REAL_HARD_FAILURES)
    real_by_key = {
        (str(row["key"]), str(row["method"]), int(row["seed"])): row
        for row in real_rows
    }
    failures_by_key = {
        (str(row["key"]), str(row["method"])): row
        for row in failure_rows
    }
    raw: list[dict[str, Any]] = []
    seed_count = int(config["seed_count"])
    for input_row in rows:
        key = str(input_row["key"])
        for method in HARD_METHODS:
            for seed in range(seed_count):
                attempts = int(config["max_attempts"])
                real = real_by_key.get((key, method, seed))
                if real is not None:
                    raw.append(runtime_row(real, input_row, method, seed, attempts))
                    continue
                failure = failures_by_key.get((key, method))
                if failure is not None:
                    raw.append(
                        not_found_row(
                            input_row,
                            method,
                            seed,
                            attempts,
                            str(failure.get("failure_reason") or "unsupported runtime constraint"),
                            "real_runtime_012_unsupported",
                        )
                    )
                    continue
                raw.append(
                    not_found_row(
                        input_row,
                        method,
                        seed,
                        attempts,
                        "missing real runtime row",
                        "real_runtime_012_missing",
                    )
                )
        for method in POSTHOC_METHODS:
            attempts = (
                int(config["repair_loop_max_attempts"])
                if method == "repair_loop_posthoc"
                else int(config["max_attempts"])
            )
            for seed in range(seed_count):
                raw.append(
                    not_found_row(
                        input_row,
                        method,
                        seed,
                        attempts,
                        "real posthoc model baseline not implemented for Experiment 005",
                        "baseline_not_run",
                    )
                )
    return raw


def summarize(raw_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for method in METHODS:
        items = [row for row in raw_rows if row["method"] == method]
        total = len(items)
        latencies = [float(row["latency_ms"]) for row in items]
        rows.append(
            {
                "method": method,
                "total": total,
                "FOUND_OK": sum(row["outcome"] == "FOUND_OK" for row in items),
                "FOUND_WRONG": sum(row["outcome"] == "FOUND_WRONG" for row in items),
                "NOT_FOUND": sum(row["outcome"] == "NOT_FOUND" for row in items),
                "SolveRate": rate(items, "FOUND_OK"),
                "WrongRate": rate(items, "FOUND_WRONG"),
                "NotFoundRate": rate(items, "NOT_FOUND"),
                "median_latency_ms": statistics.median(latencies) if latencies else 0.0,
                "p90_latency_ms": percentile(latencies, 0.90),
                "mean_generated_tokens": statistics.fmean(row["generated_tokens"] for row in items) if items else 0.0,
                "mean_attempts": statistics.fmean(row["attempts"] for row in items) if items else 0.0,
            }
        )
    return rows


def rate(items: list[dict[str, Any]], outcome: str) -> float:
    if not items:
        return 0.0
    return sum(row["outcome"] == outcome for row in items) / len(items)


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((len(ordered) - 1) * q)))
    return ordered[idx]


def write_outputs(raw_rows: list[dict[str, Any]], summary_rows: list[dict[str, Any]], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        with (output_dir / RAW_NAME).open("w", encoding="utf-8") as handle:
            for row in raw_rows:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        with (output_dir / SUMMARY_NAME).open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(summary_rows[0]))
            writer.writeheader()
            writer.writerows(summary_rows)
        hard_wrong = [
            row
            for row in raw_rows
            if row["method"] in HARD_METHODS and row["outcome"] == "FOUND_WRONG"
        ]
        wrong_path = output_dir / WRONG_FAILURES_NAME
        if hard_wrong:
            with wrong_path.open("w", encoding="utf-8") as handle:
                for row in hard_wrong:
                    handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                    handle.write("\n")
        elif wrong_path.exists():
            wrong_path.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    input_rows = read_jsonl(HARD_SUBSET_PATH)
    raw_rows = build_raw(input_rows, config)
    summary_rows = summarize(raw_rows)
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(raw_rows, summary_rows, output_dirs)
    print(
        json.dumps(
            {
                "hard_subset_rows": len(input_rows),
                "raw_rows": len(raw_rows),
                "methods": METHODS,
                "source": "012_real_model_benchmark",
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
