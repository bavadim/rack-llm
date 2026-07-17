from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .common import ARTIFACTS, assert_frozen, file_hash, frozen_manifest, run_state, set_run_state, write_json


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
        ARTIFACTS / "figures" / "reliability_data.jsonl",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError(f"archive missing required artifacts: {missing}")
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
