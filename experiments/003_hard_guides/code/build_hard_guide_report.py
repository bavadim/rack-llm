#!/usr/bin/env python3
"""Build a row-level hard-guide support report for IFBench."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from hard_guides import (
    GuideSpec,
    Unsupported,
    build_guidance_hard_grammar,
    build_ours_hard_guide,
    build_outlines_hard_grammar,
)


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"
SNAPSHOT_PATH = ROOT_DATA_DIR / "ifbench_snapshot.jsonl"
REPORT_NAME = "hard_guide_build_report.jsonl"


def read_snapshot() -> list[dict]:
    with SNAPSHOT_PATH.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def summarize_result(result: GuideSpec | Unsupported) -> dict:
    if isinstance(result, GuideSpec):
        return {
            "supported": True,
            "expected_exactness": result.expected_exactness,
            "guide_source": result.guide_source,
            "notes": result.notes,
        }
    return {"supported": False, "reason": result.reason}


def build_report(rows: list[dict]) -> list[dict]:
    report = []
    for row in rows:
        ours = build_ours_hard_guide(row)
        guidance = build_guidance_hard_grammar(row)
        outlines = build_outlines_hard_grammar(row)
        all_supported = all(
            isinstance(result, GuideSpec) for result in [ours, guidance, outlines]
        )
        report.append(
            {
                "key": row["key"],
                "instruction_id_list": row["instruction_id_list"],
                "all_systems_supported": all_supported,
                "ours": summarize_result(ours),
                "guidance": summarize_result(guidance),
                "outlines": summarize_result(outlines),
            }
        )
    return report


def write_report(report: list[dict], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        with (output_dir / REPORT_NAME).open("w", encoding="utf-8") as handle:
            for row in report:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                handle.write("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    report = build_report(read_snapshot())
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_report(report, output_dirs)
    print(
        json.dumps(
            {
                "rows": len(report),
                "all_systems_supported": sum(
                    1 for row in report if row["all_systems_supported"]
                ),
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
