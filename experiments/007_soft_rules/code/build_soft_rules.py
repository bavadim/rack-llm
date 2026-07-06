#!/usr/bin/env python3
"""Build clean/noisy soft rule datasets for the pinned IFBench snapshot."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from soft_rules import build_soft_rules


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"

SNAPSHOT_PATH = ROOT_DATA_DIR / "ifbench_snapshot.jsonl"
CONSTRAINT_MAP_PATH = ROOT_DATA_DIR / "ifbench_constraint_map.json"
RULES_NAME = "soft_ifbench_rules.jsonl"
COVERAGE_FAILURES_NAME = "soft_rule_coverage_failures.jsonl"


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def soft_supported_ids() -> set[str]:
    with CONSTRAINT_MAP_PATH.open("r", encoding="utf-8") as handle:
        constraint_map = json.load(handle)
    return {
        instruction_id
        for instruction_id, item in constraint_map.items()
        if item["soft_supported"]
    }


def build_dataset(rows: list[dict], supported_ids: set[str]) -> tuple[list[dict], list[dict]]:
    emitted = []
    failures = []
    for row in rows:
        unsupported = [
            instruction_id
            for instruction_id in row["instruction_id_list"]
            if instruction_id not in supported_ids
        ]
        if unsupported:
            failures.append(
                {
                    "key": row["key"],
                    "instruction_id_list": row["instruction_id_list"],
                    "unsupported_instruction_ids": unsupported,
                    "reason": "row contains instruction ids outside soft-supported subset",
                }
            )
            continue
        rule_sets = {
            "clean": [rule.to_json() for rule in build_soft_rules(row, 0.0)],
            "noisy_20": [rule.to_json() for rule in build_soft_rules(row, 0.2)],
            "noisy_40": [rule.to_json() for rule in build_soft_rules(row, 0.4)],
        }
        if not rule_sets["clean"]:
            failures.append(
                {
                    "key": row["key"],
                    "instruction_id_list": row["instruction_id_list"],
                    "unsupported_instruction_ids": [],
                    "reason": "soft-supported row produced no clean rules",
                }
            )
            continue
        emitted.append(
            {
                "key": row["key"],
                "prompt": row["prompt"],
                "instruction_id_list": row["instruction_id_list"],
                "kwargs": row["kwargs"],
                "rule_sets": rule_sets,
            }
        )
    if len(emitted) < 200:
        failures.append(
            {
                "key": "__coverage__",
                "instruction_id_list": [],
                "unsupported_instruction_ids": [],
                "reason": f"only {len(emitted)} rows have clean soft rules in pinned snapshot; threshold is 200 unless snapshot is smaller",
            }
        )
    return emitted, failures


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def write_outputs(dataset: list[dict], failures: list[dict], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_jsonl(output_dir / RULES_NAME, dataset)
        write_jsonl(output_dir / COVERAGE_FAILURES_NAME, failures)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    dataset, failures = build_dataset(read_jsonl(SNAPSHOT_PATH), soft_supported_ids())
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(dataset, failures, output_dirs)
    print(
        json.dumps(
            {
                "soft_rule_rows": len(dataset),
                "coverage_failures": len(failures),
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
