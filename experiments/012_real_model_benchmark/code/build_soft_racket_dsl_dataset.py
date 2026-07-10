#!/usr/bin/env python3
"""Build Experiment 012 soft-rule dataset with Racket DSL guide sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from strict_json import strict_json_dumps


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

INPUT_PATH = ROOT_DATA_DIR / "012_soft_ifbench_rules_audited.jsonl"
ROOT_OUTPUT = ROOT_DATA_DIR / "012_soft_ifbench_rules_audited_racket.jsonl"
RESULTS_OUTPUT = RESULTS_DIR / "012_soft_ifbench_rules_audited_racket.jsonl"
REPORT_OUTPUT = RESULTS_DIR / "025_soft_racket_dsl_dataset_report.json"

NOISE_LEVELS = ("clean", "noisy_20", "noisy_40")
GUIDE_MAX_TOKENS = 128


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(strict_json_dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def racket_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def racket_number(value: Any) -> str:
    number = float(value)
    if math.isinf(number):
        return "-inf.0" if number < 0 else "+inf.0"
    if math.isnan(number):
        raise ValueError("NaN rule weight is not supported")
    return repr(number)


def python_regex_to_pregexp(pattern: str) -> str:
    normalized = pattern.replace("\\n", "\n").replace("\\t", "\t")
    normalized = re.sub(r"\\U([0-9a-fA-F]{8})", lambda m: chr(int(m.group(1), 16)), normalized)
    normalized = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), normalized)
    if normalized.startswith("(?"):
        close = normalized.find(")")
        if close > 2:
            flags = normalized[2:close]
            if flags and set(flags) <= {"i", "m", "s"}:
                body = normalized[close + 1 :]
                body = remove_inline_flags(body)
                return f"(?{flags}:{body})"
    return remove_inline_flags(normalized)


def remove_inline_flags(pattern: str) -> str:
    output = pattern
    for flags in ("ims", "im", "is", "ms", "i", "m", "s"):
        output = output.replace(f"(?{flags})", "")
    return output


def rule_expr(rule: dict[str, Any]) -> str:
    pattern_type = rule.get("pattern_type")
    pattern = str(rule.get("pattern", ""))
    if pattern_type == "literal":
        return racket_string(pattern)
    if pattern_type == "regex":
        return f"(rx #px{racket_string(python_regex_to_pregexp(pattern))})"
    raise ValueError(f"unsupported pattern_type: {pattern_type!r}")


def watcher_source(rule: dict[str, Any]) -> str:
    kind = rule.get("kind")
    expr = rule_expr(rule)
    if kind == "rank":
        return f"(rank {racket_number(rule.get('weight', 0.0))} {expr})"
    if kind == "ban":
        return f"(ban {expr})"
    raise ValueError(f"unsupported rule kind: {kind!r}")


def lower_rule_set(rules: list[dict[str, Any]]) -> dict[str, Any]:
    watchers: list[str] = []
    errors: list[str] = []
    for index, rule in enumerate(rules):
        try:
            watchers.append(watcher_source(rule))
        except Exception as error:  # noqa: BLE001 - report all lowering failures.
            errors.append(f"rule[{index}] {rule.get('rule_id', '<missing>')}: {error}")
    guide_source = f"(text #:max-tokens {GUIDE_MAX_TOKENS}"
    if watchers:
        guide_source += "\n  " + "\n  ".join(watchers)
    guide_source += ")"
    digest_payload = json.dumps(watchers, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return {
        "watchers": watchers,
        "guide_source": guide_source,
        "rule_set_hash": hashlib.sha256(digest_payload).hexdigest(),
        "lowering_status": "failed" if errors else "ok",
        "lowering_errors": errors,
    }


def validate_racket_sources(rows: list[dict[str, Any]]) -> dict[str, Any]:
    sources = [
        row["racket_rule_sets"][noise]["guide_source"]
        for row in rows
        for noise in NOISE_LEVELS
    ]
    program = "#lang racket/base\n(require rack-llm)\n(define guides\n  (list\n"
    program += "\n".join(f"   {source}" for source in sources)
    program += "))\n(displayln (length guides))\n"
    temp_root = REPO_ROOT / ".agents"
    temp_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rack-llm-soft-racket-", dir=temp_root) as tmp:
        path = Path(tmp) / "validate.rkt"
        path.write_text(program, encoding="utf-8")
        completed = subprocess.run(
            ["racket", str(path)],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
        "validated_sources": len(sources),
    }


def build_dataset() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    input_rows = read_jsonl(INPUT_PATH)
    output_rows: list[dict[str, Any]] = []
    failed_rows = 0
    total_rules = 0
    total_watchers = 0
    for row in input_rows:
        racket_rule_sets = {}
        row_failed = False
        for noise in NOISE_LEVELS:
            rules = list(row["rule_sets"][noise])
            lowered = lower_rule_set(rules)
            total_rules += len(rules)
            total_watchers += len(lowered["watchers"])
            if len(lowered["watchers"]) != len(rules):
                lowered["lowering_status"] = "failed"
                lowered["lowering_errors"].append(
                    f"watcher count {len(lowered['watchers'])} != rule count {len(rules)}"
                )
            if lowered["lowering_status"] != "ok":
                row_failed = True
            racket_rule_sets[noise] = lowered
        if row_failed:
            failed_rows += 1
        output_rows.append(
            {
                "key": row["key"],
                "prompt": row["prompt"],
                "instruction_id_list": row["instruction_id_list"],
                "kwargs": row["kwargs"],
                "rule_sets": row["rule_sets"],
                "racket_rule_sets": racket_rule_sets,
            }
        )
    validation = validate_racket_sources(output_rows)
    report = {
        "input_rows": len(input_rows),
        "output_rows": len(output_rows),
        "noise_levels": list(NOISE_LEVELS),
        "total_json_rules": total_rules,
        "total_racket_watchers": total_watchers,
        "failed_rows": failed_rows,
        "racket_validation": validation,
        "uses_official_verifier": False,
    }
    return output_rows, report


def write_outputs(rows: list[dict[str, Any]], report: dict[str, Any], experiment_only: bool) -> None:
    write_jsonl(RESULTS_OUTPUT, rows)
    REPORT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    REPORT_OUTPUT.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if not experiment_only:
        write_jsonl(ROOT_OUTPUT, rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    rows, report = build_dataset()
    write_outputs(rows, report, args.experiment_only)
    print(json.dumps(report, sort_keys=True))
    if report["failed_rows"] or not report["racket_validation"]["ok"]:
        return 1
    if report["total_json_rules"] != report["total_racket_watchers"]:
        return 1
    if args.experiment_only:
        return 0
    if not ROOT_OUTPUT.exists() or not RESULTS_OUTPUT.exists():
        return 1
    if not shutil.which("racket"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
