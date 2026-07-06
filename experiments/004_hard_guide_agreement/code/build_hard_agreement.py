#!/usr/bin/env python3
"""Validate hard guide specs against the pinned IFBench official verifier."""

from __future__ import annotations

import argparse
import csv
import importlib
import json
import sys
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"
VENDOR_DIR = EXPERIMENT_DIR / "vendor" / "ifbench"

IFBENCH_COMMIT = "1091c4c3de6c1f6ed12c012ed68f11ea450b0117"
RAW_BASE_URL = (
    "https://raw.githubusercontent.com/allenai/IFBench"
    f"/{IFBENCH_COMMIT}"
)
IFBENCH_RUNTIME_FILES = [
    "instructions.py",
    "instructions_registry.py",
    "instructions_util.py",
    "evaluation_lib.py",
]

SNAPSHOT_PATH = ROOT_DATA_DIR / "ifbench_snapshot.jsonl"
HARD_REPORT_PATH = ROOT_DATA_DIR / "hard_guide_build_report.jsonl"
HARD_GUIDES_CODE = REPO_ROOT / "experiments" / "003_hard_guides" / "code"

SUBSET_NAME = "hard_ifbench_subset.jsonl"
REPORT_NAME = "hard_guide_agreement_report.csv"
FAILURES_NAME = "hard_guide_agreement_failures.jsonl"
LOW_COVERAGE_NAME = "hard_subset_low_coverage.md"


def fetch_text(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset)


def ensure_ifbench_runtime() -> None:
    VENDOR_DIR.mkdir(parents=True, exist_ok=True)
    for filename in IFBENCH_RUNTIME_FILES:
        path = VENDOR_DIR / filename
        if not path.exists():
            path.write_text(
                fetch_text(f"{RAW_BASE_URL}/{filename}"),
                encoding="utf-8",
            )


def load_official_registry():
    ensure_ifbench_runtime()
    sys.path.insert(0, str(VENDOR_DIR))
    return importlib.import_module("instructions_registry")


def non_null_kwargs(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in kwargs.items() if value is not None}


def official_check(row: dict, text: str, registry_module) -> bool:
    if not text or not text.strip():
        return False
    results = []
    for index, instruction_id in enumerate(row["instruction_id_list"]):
        instruction_cls = registry_module.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)
        kwargs = non_null_kwargs(row["kwargs"][index])
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=row["prompt"])
        results.append(bool(instruction.check_following(text)))
    return all(results)


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def hard_guides_module():
    sys.path.insert(0, str(HARD_GUIDES_CODE))
    return importlib.import_module("hard_guides")


def result_to_spec(result: dict, system: str, hard_guides):
    if not result.get("supported"):
        return None
    return hard_guides.GuideSpec(
        supported=True,
        system=system,
        instruction_ids=[],
        guide_source=result["guide_source"],
        notes=result.get("notes", ""),
        expected_exactness=result.get("expected_exactness", "unknown"),
        regex=_extract_regex(result["guide_source"]),
        choices=_extract_choices(result["guide_source"]),
    )


def _extract_regex(source: str) -> str | None:
    if "#px" in source:
        payload = source.split("#px", 1)[1].rstrip(")")
        return json.loads(payload)
    marker = "regex("
    if marker in source:
        payload = source.split(marker, 1)[1].rstrip(")")
        return json.loads(payload)
    return None


def _extract_choices(source: str) -> list[str] | None:
    if source.startswith("select(") or source.startswith("choice("):
        payload = source.split("(", 1)[1].rstrip(")")
        return json.loads(payload)
    if source.startswith("(select "):
        # Ours source is human-readable Racket; the build report already has
        # equivalent Guidance/Outlines JSON choices, so callers can use those.
        return None
    return None


def validation_pool(row: dict, specs: dict[str, Any]) -> list[dict]:
    ours = specs["ours"]
    if ours.choices:
        valid = ours.choices[:3]
        invalid = ["", "not-an-allowed-choice", ours.choices[0] + " explanation"]
    else:
        valid, invalid = regex_pool(row["instruction_id_list"][0])
    pool = []
    for text in valid:
        pool.append({"source": "synthetic_valid", "text": text})
    for text in invalid:
        pool.append({"source": "synthetic_invalid", "text": text})
    return pool


def regex_pool(instruction_id: str) -> tuple[list[str], list[str]]:
    pools = {
        "format:output_template": (
            [
                "My Answer: a My Conclusion: b Future Outlook: c",
                "My Answer: detail My Conclusion: result Future Outlook: next",
                "My Answer: x My Conclusion: y Future Outlook: z",
            ],
            ["My Answer: a", "Answer: a Conclusion: b", ""],
        ),
        "format:no_whitespace": (["abc", "A_B-1", "x/y"], ["two words", "a\nb", ""]),
        "format:title_case": (
            ["Hello World", "Alpha\nBeta", "NASA Team"],
            ["hello World", "Hello world", ""],
        ),
        "format:newline": (
            ["one\ntwo", "alpha\nbeta\ngamma", "A\nB\n"],
            ["one two", "one", ""],
        ),
        "format:list": (
            ["one SEPARATOR two", "- item\n- item", "1. item\n2. item"],
            ["one two", "SEPARATOR", ""],
        ),
        "format:sub-bullets": (
            ["* A\n - a", "* A\n  - a\n* B\n  - b", "plain"],
            ["* A", "* A\nplain", ""],
        ),
        "format:no_bullets_bullets": (
            ["First.\nSecond.\n* a\n* b", "A.\nB.\nC.\n* x\n* y", "One.\nTwo.\n* item\n* item"],
            ["First.\n* a", "* a\n* b", "First.\nSecond."],
        ),
        "format:line_indent": (
            ["A\n B\n  C", "Top\n  Mid\n    Low", "A\n B\n  C\n   D"],
            ["A\nB\nC", " A\nB\n C", ""],
        ),
        "format:quote_unquote": (
            ['"term" explanation', '"a" b\n"c" d', 'term explanation'],
            ['"term"', '"a" "b"', ""],
        ),
        "custom:csv_city": (
            [
                "ID,Country,City,Year,Count\n1,US,NY,2020,5\n2,US,SF,2021,6\n3,US,LA,2022,7\n4,US,SEA,2023,8\n5,US,BOS,2024,9\n6,US,AUS,2025,10\n7,US,DEN,2026,11",
                "ID,Country,City,Year,Count\n1,FR,Paris,2020,5\n2,DE,Berlin,2021,6\n3,IT,Rome,2022,7\n4,ES,Madrid,2023,8\n5,JP,Tokyo,2024,9\n6,UK,London,2025,10\n7,CA,Toronto,2026,11",
            ],
            ["a,b,c", '"a",b,c,d,e', ""],
        ),
        "custom:csv_quotes": (
            [
                '"StudentID"\t"Subject"\t"Grade"\t"Semester"\t"Score"\n"1"\t"Math"\t"A"\t"Fall"\t"99"\n"2"\t"Bio"\t"B"\t"Spring"\t"88"\n"3"\t"Art"\t"A"\t"Fall"\t"95"',
            ],
            ['A\tB\tC\tD\tE', '"A","B","C","D","E"', ""],
        ),
        "custom:csv_special_character": (
            [
                'ProductID,Category,Brand,Price,Stock\n1,Tools,"A&B",10,5\n2,Toys,Plain,11,6\n3,Food,Plain,12,7\n4,Books,Plain,13,8\n5,Music,Plain,14,9\n6,Games,Plain,15,10\n7,Home,Plain,16,11\n8,Auto,Plain,17,12\n9,Pet,Plain,18,13\n10,Garden,Plain,19,14\n11,Sport,Plain,20,15\n12,Office,Plain,21,16\n13,Phone,Plain,22,17\n14,Other,Plain,23,18',
            ],
            ["a,b,c", "A,B,C,D,E\n1,2,3,4,5", ""],
        ),
        "custom:date_format_list": (
            ["1800-01-01", "1769-01-01, 1821-02-03", "1799-12-31,1800-01-01"],
            ["2020-01-01", "1800/01/01", ""],
        ),
        "repeat:repeat_change": (
            ["Make useful code", "Rewrite useful code", "X useful code"],
            ["Write useful", "Write useful code now", ""],
        ),
    }
    return pools.get(instruction_id, (["valid"], ["", "invalid"]))


def agreement(values: list[tuple[bool, bool]]) -> float:
    if not values:
        return 0.0
    return sum(int(left == right) for left, right in values) / len(values)


def build_agreement() -> tuple[list[dict], list[dict], list[dict]]:
    registry = load_official_registry()
    hard_guides = hard_guides_module()
    rows_by_key = {row["key"]: row for row in read_jsonl(SNAPSHOT_PATH)}
    build_rows = read_jsonl(HARD_REPORT_PATH)
    report_rows = []
    subset_rows = []
    failures = []
    for build_row in build_rows:
        row = rows_by_key[build_row["key"]]
        if not build_row["all_systems_supported"]:
            reason = "not all hard builders supported row"
            report_rows.append(report_record(row, 0.0, 0.0, 0.0, 0, False, reason, True))
            failures.append(failure_record(row, reason, build_row))
            continue
        # Use freshly built specs for ours so Racket-like choices are preserved.
        ours_spec = hard_guides.build_ours_hard_guide(row)
        guidance_spec = hard_guides.build_guidance_hard_grammar(row)
        outlines_spec = hard_guides.build_outlines_hard_grammar(row)
        if not all(isinstance(spec, hard_guides.GuideSpec) for spec in [ours_spec, guidance_spec, outlines_spec]):
            reason = "builder result changed to unsupported"
            report_rows.append(report_record(row, 0.0, 0.0, 0.0, 0, False, reason, True))
            failures.append(failure_record(row, reason, build_row))
            continue
        specs = {"ours": ours_spec, "guidance": guidance_spec, "outlines": outlines_spec}
        pool = validation_pool(row, specs)
        comparisons = {"ours": [], "guidance": [], "outlines": []}
        pool_rows = []
        for candidate in pool:
            official = official_check(row, candidate["text"], registry)
            pool_row = {
                "source": candidate["source"],
                "text": candidate["text"],
                "official": official,
            }
            for name, spec in specs.items():
                observed = hard_guides.check_spec(spec, candidate["text"])
                comparisons[name].append((observed, official))
                pool_row[name] = observed
            pool_rows.append(pool_row)
        ours_agreement = agreement(comparisons["ours"])
        guidance_agreement = agreement(comparisons["guidance"])
        outlines_agreement = agreement(comparisons["outlines"])
        include = min(ours_agreement, guidance_agreement, outlines_agreement) >= 0.99
        reason = "" if include else "agreement below 0.99"
        report_rows.append(
            report_record(
                row,
                ours_agreement,
                guidance_agreement,
                outlines_agreement,
                len(pool),
                include,
                reason,
                True,
            )
        )
        if include:
            subset = dict(row)
            subset["hard_agreement"] = {
                "ours": ours_agreement,
                "guidance": guidance_agreement,
                "outlines": outlines_agreement,
                "validation_pool_size": len(pool),
                "baseline_check_limited": True,
            }
            subset_rows.append(subset)
        else:
            failures.append(failure_record(row, reason, build_row, pool_rows))
    return report_rows, subset_rows, failures


def report_record(row, ours, guidance, outlines, pool_size, include, reason, limited):
    return {
        "key": row["key"],
        "instruction_ids": "|".join(row["instruction_id_list"]),
        "family": row["instruction_id_list"][0].split(":", 1)[0],
        "ours_agreement": f"{ours:.6f}",
        "guidance_agreement": f"{guidance:.6f}",
        "outlines_agreement": f"{outlines:.6f}",
        "validation_pool_size": str(pool_size),
        "included": str(bool(include)).lower(),
        "failure_reason": reason,
        "baseline_check_limited": str(bool(limited)).lower(),
    }


def failure_record(row, reason, build_row, pool_rows=None):
    return {
        "key": row["key"],
        "instruction_id_list": row["instruction_id_list"],
        "failure_reason": reason,
        "build_row": build_row,
        "validation_pool": pool_rows or [],
    }


def write_outputs(report_rows, subset_rows, failures, output_dirs):
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        with (output_dir / SUBSET_NAME).open("w", encoding="utf-8") as handle:
            for row in subset_rows:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        with (output_dir / REPORT_NAME).open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(report_rows[0]))
            writer.writeheader()
            writer.writerows(report_rows)
        with (output_dir / FAILURES_NAME).open("w", encoding="utf-8") as handle:
            for row in failures:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
                handle.write("\n")
        low_coverage = output_dir / LOW_COVERAGE_NAME
        if len(subset_rows) < 50:
            low_coverage.write_text(low_coverage_markdown(subset_rows, failures), encoding="utf-8")
        elif low_coverage.exists():
            low_coverage.unlink()


def low_coverage_markdown(subset_rows, failures):
    counts = Counter(
        failure["instruction_id_list"][0].split(":", 1)[0] if failure["instruction_id_list"] else "unknown"
        for failure in failures
    )
    lines = [
        "# Hard Subset Low Coverage",
        "",
        f"Included rows: {len(subset_rows)}",
        "",
        "Failure breakdown by family:",
        "",
    ]
    for family, count in sorted(counts.items()):
        lines.append(f"- `{family}`: {count}")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    report_rows, subset_rows, failures = build_agreement()
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(report_rows, subset_rows, failures, output_dirs)
    print(
        json.dumps(
            {
                "attempted_rows": len(report_rows),
                "included_rows": len(subset_rows),
                "failures": len(failures),
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
