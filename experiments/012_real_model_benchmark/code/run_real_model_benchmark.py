#!/usr/bin/env python3
"""Paper-grade real-model benchmark preflight and runner.

This runner intentionally refuses to create benchmark metrics without a real
local model backend and runtime Guidance/Outlines dependencies.
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
    ROOT_DATA_DIR / "soft_ifbench_rules_audited.jsonl",
]
REQUIRED_PYTHON_MODULES = ["guidance", "numpy", "outlines", "torch", "transformers"]
MISSING_NAME = "MISSING_BACKEND.md"


@dataclass(frozen=True)
class Preflight:
    ok: bool
    missing: list[str]
    metadata: dict[str, Any]


def module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def preflight() -> Preflight:
    missing: list[str] = []
    model_path = os.environ.get("RACK_LLM_MODEL_PATH")
    sidecar = os.environ.get("RACK_LLM_LLAMA_SIDECAR")
    metadata: dict[str, Any] = {
        "model_path": model_path,
        "sidecar_command": sidecar,
        "python": sys.version,
        "repo_root": str(REPO_ROOT),
    }
    if not model_path:
        missing.append("RACK_LLM_MODEL_PATH is not set")
    elif not Path(model_path).exists():
        missing.append(f"RACK_LLM_MODEL_PATH does not exist: {model_path}")
    if not sidecar:
        missing.append("RACK_LLM_LLAMA_SIDECAR is not set")
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
            "- `RACK_LLM_MODEL_PATH`: local model file or directory.",
            "- `RACK_LLM_LLAMA_SIDECAR`: JSON-lines sidecar command supporting `load`, `tokenize`, `detokenize`, `next_logits`.",
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
    raise RuntimeError(
        "real runtime execution is not enabled until a concrete sidecar/model "
        "environment is supplied; preflight passed but no backend-specific "
        "adapter was selected"
    )


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
