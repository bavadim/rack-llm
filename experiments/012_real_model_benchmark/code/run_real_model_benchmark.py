#!/usr/bin/env python3
"""Paper-grade real-model benchmark package preflight.

Experiment 012 is the reproducibility/package gate. The hard and soft benchmark
rows are produced by the earlier real-runtime experiments; this script only
checks that the native backend and required inputs are present.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

REQUIRED_DATA = [
    ROOT_DATA_DIR / "ifbench_snapshot.jsonl",
    ROOT_DATA_DIR / "hard_ifbench_subset.jsonl",
    ROOT_DATA_DIR / "soft_ifbench_rules.jsonl",
]
REQUIRED_PYTHON_MODULES = ["guidance", "numpy", "outlines", "torch", "transformers"]
MISSING_NAME = "MISSING_BACKEND.md"
DEFAULT_GGUF_MODEL = "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"


@dataclass(frozen=True)
class Preflight:
    ok: bool
    missing: list[str]
    metadata: dict[str, Any]


def module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def preflight() -> Preflight:
    missing: list[str] = []
    gguf_model_path = os.environ.get("RACK_LLM_GGUF_MODEL", DEFAULT_GGUF_MODEL)
    hf_model_path = os.environ.get("RACK_LLM_HF_MODEL")
    metadata: dict[str, Any] = {
        "gguf_model_path": gguf_model_path,
        "hf_model_path": hf_model_path,
        "python": sys.version,
        "repo_root": str(REPO_ROOT),
    }
    if not os.environ.get("RACK_LLM_GGUF_MODEL"):
        missing.append("RACK_LLM_GGUF_MODEL is not set")
    elif not Path(gguf_model_path).exists():
        missing.append(f"RACK_LLM_GGUF_MODEL does not exist: {gguf_model_path}")
    if hf_model_path and not Path(hf_model_path).exists():
        missing.append(f"RACK_LLM_HF_MODEL does not exist: {hf_model_path}")
    for module in REQUIRED_PYTHON_MODULES:
        if not module_available(module):
            missing.append(f"Python module is not installed: {module}")
    if shutil.which("racket") is None:
        missing.append("racket executable is not on PATH")
    for path in REQUIRED_DATA:
        if not path.exists():
            missing.append(f"required data file is missing: {path}")
    return Preflight(ok=not missing, missing=missing, metadata=metadata)


def write_missing(preflight_result: Preflight, output_dirs: list[Path]) -> None:
    body = [
        "# Missing Real Benchmark Backend",
        "",
        "Experiment 012 is fail-closed: it does not create benchmark metrics",
        "unless a real local model backend and runtime baselines are available.",
        "",
        "## Missing Requirements",
        "",
    ]
    for item in preflight_result.missing:
        body.append(f"- {item}")
    body.extend(
        [
            "",
            "## Required Environment",
            "",
            "- `RACK_LLM_GGUF_MODEL`: local GGUF model file for the native llama.cpp provider.",
            "- `RACK_LLM_HF_MODEL`: optional local Hugging Face model directory for Guidance/Outlines baselines.",
            "- Python packages from `experiments/012_real_model_benchmark/requirements.txt`.",
            "",
            "## Metadata",
            "",
            "```json",
            json.dumps(preflight_result.metadata, indent=2, sort_keys=True),
            "```",
            "",
        ]
    )
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        (output_dir / MISSING_NAME).write_text("\n".join(body), encoding="utf-8")


def remove_stale_outputs(output_dirs: list[Path]) -> None:
    names = [
        "012_hard_real_raw.jsonl",
        "012_hard_real_summary.csv",
        "012_soft_real_raw.jsonl",
        "012_soft_real_summary.csv",
        "012_soft_real_risk_coverage.csv",
        "012_stat_tests.csv",
        "012_claims.md",
    ]
    for output_dir in output_dirs:
        for name in names:
            path = output_dir / name
            if path.exists():
                path.unlink()


def run_real_benchmark(_preflight_result: Preflight) -> int:
    print(json.dumps({"status": "READY", **asdict(_preflight_result)}, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    parser.add_argument("--allow-missing", action="store_true", help="return success when backend is missing")
    parser.add_argument("--no-write", action="store_true", help="do not remove or write benchmark artifacts")
    args = parser.parse_args(argv)
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)

    result = preflight()
    if not result.ok:
        if not args.no_write:
            remove_stale_outputs(output_dirs)
            write_missing(result, output_dirs)
        print(json.dumps({"status": "MISSING_BACKEND", **asdict(result)}, sort_keys=True))
        return 0 if args.allow_missing else 2

    return run_real_benchmark(result)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
