#!/usr/bin/env python3
"""Unit tests for final analysis helpers and outputs."""

from __future__ import annotations

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_final_analysis import paired_bootstrap_by_example, paired_by_example_method


REPO_ROOT = Path(__file__).resolve().parents[3]
ROOT_DATA_DIR = REPO_ROOT / "data"
RESULTS = ROOT_DATA_DIR


def read_csv(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def test_bootstrap_resamples_by_example() -> None:
    records = [
        {"example_id": "a", "value": 1.0},
        {"example_id": "a", "value": 1.0},
        {"example_id": "b", "value": 0.0},
    ]
    result = paired_bootstrap_by_example(records, lambda sample: sum(item["value"] for item in sample) / len(sample), resamples=100, seed=1)
    assert result["unit"] == "example_id"
    assert result["resamples"] == 100
    assert 0.0 <= result["ci_low"] <= result["ci_high"] <= 1.0


def test_missing_rows_not_dropped() -> None:
    rows = [{"example_id": "a", "method": "left", "outcome": "FOUND_OK"}]
    try:
        paired_by_example_method(rows, "left", "right", lambda row: True)
    except ValueError as error:
        assert "missing paired rows" in str(error)
    else:
        raise AssertionError("missing paired rows were silently accepted")


def test_oracle_not_in_main_comparison() -> None:
    tests = read_csv(RESULTS / "011_stat_tests.csv")
    assert tests
    assert not any("oracle_verifier_selection" in row["comparison"] for row in tests)


def test_required_outputs_exist() -> None:
    for name in [
        "011_hard_final_table.csv",
        "011_soft_final_table.csv",
        "011_stat_tests.csv",
        "011_claims.md",
    ]:
        assert (RESULTS / name).exists()
    claims = (RESULTS / "011_claims.md").read_text(encoding="utf-8")
    assert "hard non-inferiority" in claims
    assert "soft noisy rules" in claims


def test_figures_are_png() -> None:
    for name in [
        "011_hard_solve_vs_time.png",
        "011_soft_risk_coverage.png",
        "011_noise_robustness.png",
        "011_first_gold_rank.png",
    ]:
        path = REPO_ROOT / "experiments" / "011_final_analysis" / "figures" / name
        assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")


def main() -> int:
    tests = [
        test_bootstrap_resamples_by_example,
        test_missing_rows_not_dropped,
        test_oracle_not_in_main_comparison,
        test_required_outputs_exist,
        test_figures_are_png,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
