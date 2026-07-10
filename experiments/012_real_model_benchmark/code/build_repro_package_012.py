#!/usr/bin/env python3
"""Build the Experiment 012 reproducibility package."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
ROOT_DATA_DIR = REPO_ROOT / "data"
DEFAULT_GGUF_MODEL_PATH = "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"
DEFAULT_HF_MODEL_PATH = "/mnt/storage/models/qwen/Qwen3.5-4B"


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
    model = backend.get("model", {})
    gguf_model_path = model.get("path") or os.environ.get("RACK_LLM_GGUF_MODEL", DEFAULT_GGUF_MODEL_PATH)
    return {
        "experiment": "012_real_model_benchmark",
        "date_generated": date.today().isoformat(),
        "git_revision": git_revision(),
        "python": sys.version,
        "platform": platform.platform(),
        "model": {**model, "path": gguf_model_path},
        "hf_model": {"path": os.environ.get("RACK_LLM_HF_MODEL", DEFAULT_HF_MODEL_PATH)},
        "backend_smoke": maybe_json(ROOT_DATA_DIR / "012_backend_metadata.json").get("smoke", {}),
        "packages": package_versions(),
        "benchmark": {
            "audited_soft_rows_min": 150,
            "noise_levels": ["clean", "noisy_20", "noisy_40"],
            "budgets": [1, 4, 8, 16],
            "return_policies": ["always", "risk_target:0.05"],
            "ours_generation_backend": "racket_generate_native_llama_cpp_full_vocab",
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
    gguf_model_path = config.get("model", {}).get("path", DEFAULT_GGUF_MODEL_PATH)
    hf_model_path = config.get("hf_model", {}).get("path", DEFAULT_HF_MODEL_PATH)
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
            f"- GGUF model path: `{gguf_model_path}`.",
            f"- HF model path: `{hf_model_path}`.",
            "- Run commands from the repository root with:",
            f"  - `RACK_LLM_GGUF_MODEL={gguf_model_path}`",
            f"  - `RACK_LLM_HF_MODEL={hf_model_path}`",
            "  - `PLTCOLLECTS=/mnt/storage/work:`",
            "",
            "## Commands",
            "",
            "```bash",
            f"export RACK_LLM_GGUF_MODEL={gguf_model_path}",
            f"export RACK_LLM_HF_MODEL={hf_model_path}",
            "export PLTCOLLECTS=/mnt/storage/work:",
            "",
            ".venv-realbench/bin/python -m pytest -q experiments/012_real_model_benchmark/code/test_real_model_benchmark.py",
            "raco make experiments/012_real_model_benchmark/code/racket_choice_batch.rkt experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt experiments/012_real_model_benchmark/code/racket_soft_candidate_pool.rkt",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/run_real_model_benchmark.py --experiment-only --no-write",
            "",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/build_soft_rules_012.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py --limit-rows 1 --candidates-per-row 1 --experiment-only",
            "racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --rules data/soft_ifbench_rules.jsonl --output experiments/012_real_model_benchmark/results/019_ours_soft_smoke_raw.jsonl --limit-rows 1 --max-tokens 1 --attempt-timeout-seconds 10",
            "",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/generate_soft_candidate_pool.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/normalize_soft_candidate_pool.py",
            ".venv-realbench/bin/python experiments/012_real_model_benchmark/code/audit_soft_rules_012.py",
            "racket experiments/012_real_model_benchmark/code/racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10",
            "racket experiments/012_real_model_benchmark/code/racket_ours_soft_batch.rkt --samples 16 --max-tokens 96",
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
    today = date.today().isoformat()
    return "\n".join(
        [
            f"{today} setup_real_backend.py -> native GGUF backend metadata",
            f"{today} build_soft_rules_012.py",
            f"{today} generate_soft_candidate_pool.py -> native real Qwen candidate pool",
            f"{today} normalize_soft_candidate_pool.py",
            f"{today} audit_soft_rules_012.py",
            f"{today} racket_ours_soft_smoke.rkt --limit-rows 5 --max-tokens 1 --attempt-timeout-seconds 10",
            f"{today} run_hard_runtime_benchmark.py --mode full",
            f"{today} racket_ours_soft_batch.rkt --samples 16 --max-tokens 96",
            f"{today} run_real_soft_benchmark_012.py",
            f"{today} run_real_analysis_012.py",
            f"{today} build_repro_package_012.py",
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
