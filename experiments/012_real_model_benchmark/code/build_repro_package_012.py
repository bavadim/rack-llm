#!/usr/bin/env python3
"""Build the Experiment 012 reproducibility package."""

from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
ROOT_DATA_DIR = REPO_ROOT / "data"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def maybe_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def package_versions() -> dict[str, str]:
    packages = {}
    for name in ["torch", "transformers", "accelerate", "regex", "numpy", "scipy"]:
        try:
            module = __import__(name)
            packages[name] = str(getattr(module, "__version__", "unknown"))
        except Exception:
            packages[name] = "not-installed"
    return packages


def git_revision() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()
    except Exception:
        return "unknown"


def final_artifacts() -> list[Path]:
    names = [
        "012_hard_real_raw.jsonl",
        "012_hard_real_summary.csv",
        "012_hard_runtime_failures.jsonl",
        "012_ours_soft_generation_raw.jsonl",
        "012_soft_real_raw.jsonl",
        "012_soft_real_summary.csv",
        "012_soft_real_risk_coverage.csv",
        "012_missing_runs.json",
        "012_hard_final_table.csv",
        "012_soft_final_table.csv",
        "012_stat_tests.csv",
        "012_claims.md",
        "019_ours_soft_smoke_raw.jsonl",
    ]
    paths = [RESULTS_DIR / name for name in names if (RESULTS_DIR / name).exists()]
    paths.extend(sorted(FIGURES_DIR.glob("012_*.png")))
    return paths


def build_config() -> dict[str, Any]:
    backend = maybe_json(ROOT_DATA_DIR / "012_backend_metadata.json")
    return {
        "experiment": "012_real_model_benchmark",
        "date_generated": "2026-07-05",
        "git_revision": git_revision(),
        "python": sys.version,
        "platform": platform.platform(),
        "model": backend.get("model", {}),
        "backend_smoke": {
            "python_sidecar": maybe_json(ROOT_DATA_DIR / "012_sidecar_smoke.json"),
            "racket_sidecar": maybe_json(ROOT_DATA_DIR / "012_racket_sidecar_smoke.json"),
        },
        "packages": package_versions(),
        "benchmark": {
            "audited_soft_rows_min": 150,
            "noise_levels": ["clean", "noisy_20", "noisy_40"],
            "budgets": [1, 4, 8, 16],
            "return_policies": ["always", "risk_target:0.05"],
            "ours_generation_provider_mode": "exact-full-vocab",
            "ours_generation_approximation": "none",
            "ours_generation_max_tokens": 96,
            "pilot_outputs_005_011_are_paper_grade": False,
        },
    }


def build_manifest() -> dict[str, Any]:
    artifacts = []
    for path in final_artifacts():
        artifacts.append(
            {
                "path": str(path.relative_to(REPO_ROOT)),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    return {
        "experiment": "012_real_model_benchmark",
        "artifact_count": len(artifacts),
        "artifacts": artifacts,
        "pilot_outputs_005_011": "non-paper-grade; retained only as development pilots",
    }


def reproduce_md(config: dict[str, Any], manifest: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# Reproduce Experiment 012",
            "",
            "This package is the paper-grade real benchmark package. Pilot artifacts `005-011` are non-paper-grade and must not be used as evidence for claims.",
            "",
            "## Environment",
            "",
            "- Create `.venv-realbench` and install `experiments/012_real_model_benchmark/requirements.txt`.",
            "- Ensure Racket is on `PATH`.",
            f"- Model path: `{config.get('model', {}).get('path', 'unknown')}`.",
            "",
            "## Commands",
            "",
            "```bash",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_soft_rules_012.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py --help",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/normalize_soft_candidate_pool.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/audit_soft_rules_012.py",
            "racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10",
            "racket experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt --samples 16 --provider-mode exact-full-vocab --max-tokens 96",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_hard_runtime_benchmark.py --mode full",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_soft_benchmark_012.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_analysis_012.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_repro_package_012.py",
            "```",
            "",
            "## Artifact Hashes",
            "",
            f"`ARTIFACT_MANIFEST.json` records sha256 for {manifest['artifact_count']} final artifacts.",
            "",
        ]
    )


def command_log() -> str:
    return "\n".join(
        [
            "2026-07-05 build_soft_rules_012.py",
            "2026-07-05 generate/normalize real Qwen soft candidate pool",
            "2026-07-05 audit_soft_rules_012.py -> audited_rows=152",
            "2026-07-05 racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10",
            "2026-07-05 run_hard_runtime_benchmark.py --mode full -> raw_rows=165, failures=138",
            "2026-07-05 racket_ours_soft_batch.rkt --samples 16 --provider-mode exact-full-vocab --max-tokens 96 -> rows=14592",
            "2026-07-05 run_real_soft_benchmark_012.py -> raw_rows=25536, missing_runs=0",
            "2026-07-05 run_real_analysis_012.py -> hard_rows=3, soft_rows=84, test_rows=6",
            "2026-07-05 build_repro_package_012.py",
            "",
        ]
    )


def main() -> int:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    config = build_config()
    manifest = build_manifest()
    (EXPERIMENT_DIR / "config.lock.json").write_text(json.dumps(config, indent=2, sort_keys=True), encoding="utf-8")
    (EXPERIMENT_DIR / "ARTIFACT_MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    (EXPERIMENT_DIR / "REPRODUCE.md").write_text(reproduce_md(config, manifest), encoding="utf-8")
    (RESULTS_DIR / "command_log.txt").write_text(command_log(), encoding="utf-8")
    print(json.dumps({"artifacts": manifest["artifact_count"], "config": str(EXPERIMENT_DIR / "config.lock.json")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
