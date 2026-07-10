#!/usr/bin/env python3
"""Normalize generated soft candidate text and refresh verifier labels."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
ROOT_DATA_DIR = REPO_ROOT / "data"
RESULTS_DIR = EXPERIMENT_DIR / "results"
POOL_NAME = "012_soft_candidate_pool.jsonl"

sys.path.insert(0, str(EXPERIMENT_DIR / "code"))
from run_hard_runtime_benchmark import official_check, load_registry  # noqa: E402
from strict_json import strict_json_dumps  # noqa: E402


SPECIAL_TOKEN_RE = re.compile(r"<\|(?:im_start|im_end|endoftext)\|>")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(strict_json_dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def normalize_text(text: str) -> str:
    return SPECIAL_TOKEN_RE.sub("", text).strip()


def normalize_pool(pool: list[dict[str, Any]], rule_rows: dict[str, dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, int]]:
    registry = load_registry()
    normalized = []
    stats = {"rows": 0, "text_changed": 0, "label_changed": 0}
    for candidate in pool:
        row = dict(candidate)
        stats["rows"] += 1
        old_text = str(row.get("text", ""))
        new_text = normalize_text(old_text)
        if new_text != old_text:
            stats["text_changed"] += 1
        old_label = bool(row.get("official_verifier"))
        new_label = official_check(rule_rows[str(row["key"])], new_text, registry) if new_text else False
        if new_label != old_label:
            stats["label_changed"] += 1
        row["text"] = new_text
        row["official_verifier"] = new_label
        metadata = dict(row.get("generation_metadata", {}))
        metadata["text_normalized"] = True
        metadata["normalization"] = "strip_visible_special_tokens"
        row["generation_metadata"] = metadata
        normalized.append(row)
    return normalized, stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pool", type=Path, default=ROOT_DATA_DIR / POOL_NAME)
    parser.add_argument("--rules", type=Path, default=ROOT_DATA_DIR / "soft_ifbench_rules.jsonl")
    parser.add_argument("--experiment-copy", type=Path, default=RESULTS_DIR / POOL_NAME)
    args = parser.parse_args(argv)
    rule_rows = {str(row["key"]): row for row in read_jsonl(args.rules)}
    rows, stats = normalize_pool(read_jsonl(args.pool), rule_rows)
    backup = args.pool.with_suffix(args.pool.suffix + ".pre_normalize.bak")
    if not backup.exists():
        shutil.copyfile(args.pool, backup)
    write_jsonl(args.pool, rows)
    write_jsonl(args.experiment_copy, rows)
    print(json.dumps(stats, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
