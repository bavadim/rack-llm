#!/usr/bin/env python3
"""Publish real soft noisy-rules artifacts in the Experiment 010 schema.

The old Experiment 010 runner used an offline surrogate candidate pool for all
methods. The current paper-grade data is produced by Experiment 012:

* pool baselines use real Qwen candidate pools;
* ours_* methods use Racket generation-time rows;
* every method/noise/N/policy combination is fail-closed in missing_runs.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

SOURCE_RAW = ROOT_DATA_DIR / "012_soft_real_raw.jsonl"
SOURCE_SUMMARY = ROOT_DATA_DIR / "012_soft_real_summary.csv"
SOURCE_RISK = ROOT_DATA_DIR / "012_soft_real_risk_coverage.csv"
SOURCE_MISSING = ROOT_DATA_DIR / "012_missing_runs.json"

RAW_NAME = "010_soft_noisy_raw.jsonl"
SUMMARY_NAME = "010_soft_noisy_summary.csv"
RISK_NAME = "010_soft_noisy_risk_coverage.csv"
MISSING_NAME = "010_missing_runs.json"

METHOD_NAMES = [
    "vanilla",
    "best_of_n_lm",
    "weak_posthoc_rerank",
    "weak_rejection",
    "ours_soft_decoding",
    "ours_hybrid_decoding",
    "oracle_verifier_selection",
]
NOISE_LEVELS = ["clean", "noisy_20", "noisy_40"]
BUDGETS = [1, 4, 8, 16]
POLICIES = ["always", "risk_target:0.05"]


def require(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"required real artifact is missing: {path}")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    require(path)
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_csv(path: Path) -> list[dict[str, str]]:
    require(path)
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def validate_complete(raw: list[dict[str, Any]], missing: list[dict[str, Any]]) -> None:
    if missing:
        raise SystemExit(f"real soft benchmark has missing runs: {missing[:3]}")
    keys = {str(row["example_id"]) for row in raw}
    expected = len(keys)
    if expected == 0:
        raise SystemExit("real soft benchmark has no rows")
    counts: dict[tuple[str, str, int, str], int] = {}
    for row in raw:
        key = (str(row["method"]), str(row["noise"]), int(row["N"]), str(row["policy"]))
        counts[key] = counts.get(key, 0) + 1
    bad = []
    for method in METHOD_NAMES:
        for noise in NOISE_LEVELS:
            for n in BUDGETS:
                for policy in POLICIES:
                    actual = counts.get((method, noise, n, policy), 0)
                    if actual != expected:
                        bad.append(
                            {
                                "method": method,
                                "noise": noise,
                                "N": n,
                                "policy": policy,
                                "expected": expected,
                                "actual": actual,
                            }
                        )
    if bad:
        raise SystemExit(f"real soft benchmark is incomplete: {bad[:3]}")


def copy_outputs(output_dirs: list[Path]) -> None:
    raw = read_jsonl(SOURCE_RAW)
    summary = read_csv(SOURCE_SUMMARY)
    risk = read_csv(SOURCE_RISK)
    missing = json.loads(SOURCE_MISSING.read_text(encoding="utf-8"))
    validate_complete(raw, missing)
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE_RAW, output_dir / RAW_NAME)
        shutil.copyfile(SOURCE_SUMMARY, output_dir / SUMMARY_NAME)
        shutil.copyfile(SOURCE_RISK, output_dir / RISK_NAME)
        shutil.copyfile(SOURCE_MISSING, output_dir / MISSING_NAME)
    print(
        json.dumps(
            {
                "raw_rows": len(raw),
                "summary_rows": len(summary),
                "risk_rows": len(risk),
                "missing_runs": len(missing),
                "source": "012_real_model_benchmark",
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    copy_outputs(output_dirs)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
