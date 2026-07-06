#!/usr/bin/env python3
"""Build the pinned IFBench snapshot used by rack-llm paper experiments."""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path


IFBENCH_REPO_URL = "https://github.com/allenai/IFBench"
IFBENCH_COMMIT = "1091c4c3de6c1f6ed12c012ed68f11ea450b0117"
SOURCE_FILE = "data/IFBench_test.jsonl"
REGISTRY_FILE = "instructions_registry.py"

RAW_BASE_URL = (
    "https://raw.githubusercontent.com/allenai/IFBench"
    f"/{IFBENCH_COMMIT}"
)

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"

SNAPSHOT_NAME = "ifbench_snapshot.jsonl"
META_NAME = "ifbench_snapshot_meta.json"


def fetch_text(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def parse_registry_ids(registry_source: str) -> set[str]:
    in_dict = False
    ids: set[str] = set()
    key_pattern = re.compile(r'^\s*"([^"]+)"\s*:')
    for line in registry_source.splitlines():
        if line.startswith("INSTRUCTION_DICT"):
            in_dict = True
            continue
        if in_dict and line.strip() == "}":
            break
        if in_dict:
            match = key_pattern.match(line)
            if match:
                ids.add(match.group(1))
    if not ids:
        raise RuntimeError("No instruction ids found in instructions_registry.py")
    return ids


def canonical_row(raw_line: str, line_number: int) -> dict:
    try:
        row = json.loads(raw_line)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON at line {line_number}: {exc}") from exc

    required = ["key", "prompt", "instruction_id_list", "kwargs"]
    missing = [field for field in required if field not in row]
    if missing:
        raise ValueError(f"Missing fields at line {line_number}: {missing}")

    if not isinstance(row["instruction_id_list"], list):
        raise ValueError(f"instruction_id_list must be a list at line {line_number}")
    if not isinstance(row["kwargs"], list):
        raise ValueError(f"kwargs must be a list at line {line_number}")

    return {
        "key": str(row["key"]),
        "prompt": row["prompt"],
        "instruction_id_list": row["instruction_id_list"],
        "kwargs": row["kwargs"],
        "raw_row_sha256": sha256_text(raw_line),
    }


def build_snapshot(raw_jsonl: str, registry_source: str) -> tuple[list[dict], dict]:
    registry_ids = parse_registry_ids(registry_source)
    snapshot: list[dict] = []
    unique_instruction_ids: set[str] = set()
    missing_registry_ids: set[str] = set()

    for line_number, raw_line in enumerate(raw_jsonl.splitlines(), start=1):
        if not raw_line.strip():
            continue
        row = canonical_row(raw_line, line_number)
        row_ids = set(row["instruction_id_list"])
        unique_instruction_ids.update(row_ids)
        missing_registry_ids.update(row_ids - registry_ids)
        snapshot.append(row)

    if missing_registry_ids:
        missing = ", ".join(sorted(missing_registry_ids))
        raise RuntimeError(f"Instruction ids missing from registry: {missing}")

    meta = {
        "ifbench_repo_url": IFBENCH_REPO_URL,
        "ifbench_commit": IFBENCH_COMMIT,
        "source_file": SOURCE_FILE,
        "registry_file": REGISTRY_FILE,
        "num_rows": len(snapshot),
        "num_unique_instruction_ids": len(unique_instruction_ids),
        "registry_num_instruction_ids": len(registry_ids),
        "source_sha256": sha256_text(raw_jsonl),
        "registry_sha256": sha256_text(registry_source),
        "created_at_utc": _dt.datetime.now(_dt.UTC)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
    }
    return snapshot, meta


def write_outputs(snapshot: list[dict], meta: dict, output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        snapshot_path = output_dir / SNAPSHOT_NAME
        meta_path = output_dir / META_NAME
        with snapshot_path.open("w", encoding="utf-8") as handle:
            for row in snapshot:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        with meta_path.open("w", encoding="utf-8") as handle:
            json.dump(meta, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--experiment-only",
        action="store_true",
        help="write only experiments/001_ifbench_snapshot/data artifacts",
    )
    args = parser.parse_args(argv)

    raw_jsonl = fetch_text(f"{RAW_BASE_URL}/{SOURCE_FILE}")
    registry_source = fetch_text(f"{RAW_BASE_URL}/{REGISTRY_FILE}")
    snapshot, meta = build_snapshot(raw_jsonl, registry_source)
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(snapshot, meta, output_dirs)

    print(
        json.dumps(
            {
                "snapshot_rows": meta["num_rows"],
                "unique_instruction_ids": meta["num_unique_instruction_ids"],
                "ifbench_commit": IFBENCH_COMMIT,
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
