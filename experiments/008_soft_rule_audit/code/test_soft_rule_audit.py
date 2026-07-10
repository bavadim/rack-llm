#!/usr/bin/env python3
"""Unit tests for Experiment 008 soft rule audit outputs."""

from __future__ import annotations

import ast
import csv
import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
ROOT_DATA_DIR = REPO_ROOT / "data"
RULE_BUILDER = REPO_ROOT / "experiments" / "007_soft_rules" / "code" / "soft_rules.py"
AUDIT_CSV = ROOT_DATA_DIR / "soft_rule_audit.csv"
AUDITED_RULES = ROOT_DATA_DIR / "soft_ifbench_rules_audited.jsonl"
POOL = ROOT_DATA_DIR / "soft_rule_candidate_pool.jsonl"
FAILURES = ROOT_DATA_DIR / "soft_rule_audit_failures.md"
RUNNER = REPO_ROOT / "experiments" / "008_soft_rule_audit" / "code" / "run_soft_rule_audit.py"
REAL_POOL = ROOT_DATA_DIR / "012_soft_candidate_pool.jsonl"


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_audit() -> list[dict]:
    with AUDIT_CSV.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def test_no_trivial_clean_watchers() -> None:
    if not AUDIT_CSV.exists():
        return
    accepted = [
        row
        for row in read_audit()
        if row["accepted"] == "True" and row["noise"] == "False"
    ]
    for row in accepted:
        coverage = float(row["coverage"])
        assert 0.02 <= coverage <= 0.98, row


def test_audit_has_verifier_column() -> None:
    if not POOL.exists() or not AUDIT_CSV.exists():
        return
    pool_rows = read_jsonl(POOL)
    assert pool_rows and "official_verifier" in pool_rows[0]
    assert "synthetic" not in str(pool_rows[0].get("pool_source", "")).lower()
    audit_rows = read_audit()
    assert audit_rows and "gold_verifier_rate" in audit_rows[0]
    source = RULE_BUILDER.read_text(encoding="utf-8")
    assert "official_verifier" not in source
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            assert all(alias.name.split(".")[0] != "evaluation_lib" for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            assert (node.module or "").split(".")[0] != "evaluation_lib"


def test_audited_rows_have_min_rules() -> None:
    if not AUDITED_RULES.exists():
        return
    for row in read_jsonl(AUDITED_RULES):
        assert len(row["rule_sets"]["clean"]) >= 3, row["key"]


def test_required_outputs_exist() -> None:
    if POOL.exists():
        assert AUDIT_CSV.exists()
        assert AUDITED_RULES.exists()
        assert FAILURES.exists()
        assert "required_survivors: 150" in FAILURES.read_text(encoding="utf-8")
        return
    completed = subprocess.run(
        [sys.executable, str(RUNNER), "--experiment-only"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )
    assert completed.returncode != 0
    assert str(REAL_POOL) in (completed.stdout + completed.stderr)


def main() -> int:
    tests = [
        test_no_trivial_clean_watchers,
        test_audit_has_verifier_column,
        test_audited_rows_have_min_rules,
        test_required_outputs_exist,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
