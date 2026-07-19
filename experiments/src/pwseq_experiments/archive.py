from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .common import ARTIFACTS, assert_frozen, file_hash, frozen_manifest, read_jsonl, run_state, set_run_state, write_json


def archive() -> Path:
    assert_frozen()
    manifest = frozen_manifest()
    if manifest is None or ARTIFACTS.name == "setup":
        raise RuntimeError("no active frozen run to archive")
    if run_state() != "READY_TO_ARCHIVE":
        raise RuntimeError(f"archive requires READY_TO_ARCHIVE state, got {run_state()}")
    partials = sorted(ARTIFACTS.rglob("*.partial"))
    if partials:
        raise RuntimeError(f"archive contains partial files: {partials[:5]}")
    required = [
        ARTIFACTS / "stage_status.json", ARTIFACTS / "CLAIMS.json",
        ARTIFACTS / "tables" / "statistical_tests.jsonl",
        ARTIFACTS / "tables" / "table3_generation.csv",
        ARTIFACTS / "tables" / "table5_mixed_hard_weak.csv",
        ARTIFACTS / "thresholds" / "main_noise_00.jsonl",
        ARTIFACTS / "figures" / "risk_coverage.png",
        ARTIFACTS / "figures" / "risk_coverage_data.jsonl",
        ARTIFACTS / "figures" / "quality_vs_budget.png",
        ARTIFACTS / "figures" / "quality_vs_budget_data.jsonl",
        ARTIFACTS / "figures" / "noise_robustness.png",
        ARTIFACTS / "figures" / "noise_robustness_data.jsonl",
        ARTIFACTS / "figures" / "found_wrong_vs_not_found.png",
        ARTIFACTS / "figures" / "reliability.png",
        ARTIFACTS / "figures" / "reliability_data.jsonl",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError(f"archive missing required artifacts: {missing}")
    figure_schemas = {
        "risk_coverage_data.jsonl": {
            "coverage", "risk", "risk_ci_low", "risk_ci_high",
            "bootstrap_repetitions", "bootstrap_support",
            "bootstrap_support_fraction",
        },
        "quality_vs_budget_data.jsonl": {
            "mean_model_tokens", "solve_rate", "solve_rate_ci_low",
            "solve_rate_ci_high", "solve_rate_support",
        },
        "noise_robustness_data.jsonl": {
            "noise", "solve_rate", "solve_rate_ci_low", "solve_rate_ci_high",
            "solve_rate_support", "found_wrong_rate", "found_wrong_rate_ci_low",
            "found_wrong_rate_ci_high", "found_wrong_rate_support",
            "not_found_rate", "not_found_rate_ci_low", "not_found_rate_ci_high",
            "not_found_rate_support",
        },
        "reliability_data.jsonl": {
            "mean_probability", "empirical_rate", "empirical_rate_ci_low",
            "empirical_rate_ci_high", "bootstrap_repetitions", "bootstrap_support",
        },
    }
    for filename, fields in figure_schemas.items():
        rows = read_jsonl(ARTIFACTS / "figures" / filename)
        if not rows:
            raise RuntimeError(f"archive figure data is empty: {filename}")
        invalid = [index for index, row in enumerate(rows) if not fields <= set(row)]
        if invalid:
            raise RuntimeError(
                f"archive figure data lacks CI/support fields: {filename} rows {invalid[:5]}"
            )
        if any(
            row[key] is None
            for row in rows
            for key in fields
            if key.endswith("_ci_low") or key.endswith("_ci_high")
        ):
            raise RuntimeError(f"archive figure data has missing confidence bounds: {filename}")
        if any(
            not [key for key in row if key.endswith("_support")]
            or any(int(row[key]) <= 0 for key in row if key.endswith("_support"))
            for row in rows
        ):
            raise RuntimeError(f"archive figure data has zero bootstrap support: {filename}")
    risk_rows = read_jsonl(ARTIFACTS / "figures" / "risk_coverage_data.jsonl")
    if any(float(row["bootstrap_support_fraction"]) < .95 for row in risk_rows):
        raise RuntimeError("archive risk-coverage data violates 95% support gate")
    release_files = sorted(
        path for path in ARTIFACTS.rglob("*")
        if path.is_file() and path.name != "release_manifest.json"
    )
    write_json(ARTIFACTS / "release_manifest.json", {
        "run_id": manifest["run_id"],
        "files": {str(path.relative_to(ARTIFACTS)): file_hash(path) for path in release_files},
    })
    run_id = manifest["run_id"]
    destination = Path(
        os.environ.get("PWSEQ_ARCHIVE_DIR", "/mnt/storage/work/rack-llm-results")
    )
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / f"pwseq-ifbench-{run_id}.tar.zst"
    checksum = target.with_suffix(target.suffix + ".sha256")
    if target.exists() or checksum.exists():
        raise FileExistsError(f"immutable archive already exists: {target}")
    temporary = target.with_suffix(target.suffix + ".partial")
    try:
        subprocess.run(
            ["tar", "--zstd", "-cf", str(temporary), "-C", str(ARTIFACTS.parent), ARTIFACTS.name],
            check=True,
        )
        digest = file_hash(temporary)
        os.replace(temporary, target)
        checksum.write_text(f"{digest}  {target.name}\n", encoding="utf-8")
        set_run_state("ARCHIVED", archive=str(target), sha256=digest)
    finally:
        if temporary.exists():
            temporary.unlink()
    return target
