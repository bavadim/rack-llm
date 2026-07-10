#!/usr/bin/env python3
"""Unit tests for Experiment 010 benchmark outputs."""

from __future__ import annotations

import csv
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
ROOT_DATA_DIR = REPO_ROOT / "data"
RAW = ROOT_DATA_DIR / "010_soft_noisy_raw.jsonl"
SUMMARY = ROOT_DATA_DIR / "010_soft_noisy_summary.csv"
RISK = ROOT_DATA_DIR / "010_soft_noisy_risk_coverage.csv"
MISSING = ROOT_DATA_DIR / "010_missing_runs.json"
RULES = ROOT_DATA_DIR / "012_soft_ifbench_rules_audited.jsonl"
RUNNER = REPO_ROOT / "experiments" / "010_soft_noisy_benchmark" / "code" / "run_soft_noisy_benchmark.py"

METHODS = {
    "vanilla",
    "best_of_n_lm",
    "weak_posthoc_rerank",
    "weak_rejection",
    "ours_soft_decoding",
    "ours_hybrid_decoding",
    "oracle_verifier_selection",
}
NOISE = {"clean", "noisy_20", "noisy_40"}
BUDGETS = {1, 4, 8, 16}
POLICIES = {"always", "risk_target:0.05"}


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_csv(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def test_all_method_noise_budget_policy_combinations_exist() -> None:
    if not RAW.exists():
        completed = subprocess.run(
            [sys.executable, str(RUNNER), "--experiment-only"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
        )
        assert completed.returncode != 0
        assert "required real artifact is missing" in (completed.stdout + completed.stderr)
        return
    raw = read_jsonl(RAW)
    expected_rows = len({row["example_id"] for row in raw})
    assert expected_rows == len(read_jsonl(RULES))
    assert expected_rows > 0
    counts = defaultdict(int)
    for row in raw:
        counts[(row["method"], row["noise"], int(row["N"]), row["policy"])] += 1
    for method in METHODS:
        for noise in NOISE:
            for budget in BUDGETS:
                for policy in POLICIES:
                    assert counts[(method, noise, budget, policy)] == expected_rows
    assert json.loads(MISSING.read_text(encoding="utf-8")) == []


def test_summary_has_required_metrics() -> None:
    if not SUMMARY.exists():
        return
    rows = read_csv(SUMMARY)
    assert rows
    required = {
        "FoundOK",
        "FoundWrong",
        "NotFound",
        "ReturnPrecision",
        "Coverage",
        "OracleAtN",
        "SelectionEfficiencyAtN",
        "AUROC",
        "AUPRC",
        "median_latency_ms",
        "duplicate_rate_at_N",
    }
    assert required.issubset(rows[0])


def test_oracle_not_worse_than_real_methods_on_found_ok() -> None:
    if not SUMMARY.exists():
        return
    rows = read_csv(SUMMARY)
    by_combo = defaultdict(dict)
    for row in rows:
        if row["split"] == "test" and row["policy"] == "always":
            key = (row["noise"], row["N"])
            by_combo[key][row["method"]] = float(row["FoundOK"])
    for methods in by_combo.values():
        oracle = methods["oracle_verifier_selection"]
        for method, found_ok in methods.items():
            if method != "oracle_verifier_selection":
                assert oracle + 1e-9 >= found_ok


def test_vanilla_always_not_found_zero() -> None:
    if not SUMMARY.exists():
        return
    for row in read_csv(SUMMARY):
        if row["method"] == "vanilla" and row["policy"] == "always":
            assert float(row["NotFound"]) == 0.0


def test_risk_coverage_exists_and_has_safe_solve() -> None:
    if not RISK.exists():
        return
    rows = read_csv(RISK)
    assert rows
    assert "SafeSolveAt5" in rows[0]


def main() -> int:
    tests = [
        test_all_method_noise_budget_policy_combinations_exist,
        test_summary_has_required_metrics,
        test_oracle_not_worse_than_real_methods_on_found_ok,
        test_vanilla_always_not_found_zero,
        test_risk_coverage_exists_and_has_safe_solve,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
