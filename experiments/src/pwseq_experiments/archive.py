from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .common import ARTIFACTS, file_hash, frozen_manifest


def archive() -> Path:
    manifest = frozen_manifest()
    if manifest is None or ARTIFACTS.name == "setup":
        raise RuntimeError("no active frozen run to archive")
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
    finally:
        if temporary.exists():
            temporary.unlink()
    return target
