#!/usr/bin/env python3
"""Validation tests for hard convergence artifacts."""

from __future__ import annotations

import csv
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RUNNER = EXPERIMENT_DIR / "code" / "run_hard_convergence.py"
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
RAW_PATH = RESULTS_DIR / "006_hard_convergence_raw.jsonl"
TIME_CSV = RESULTS_DIR / "006_hard_solve_by_time.csv"
TOKENS_CSV = RESULTS_DIR / "006_hard_solve_by_tokens.csv"
ATTEMPTS_CSV = RESULTS_DIR / "006_hard_solve_by_attempts.csv"
SOURCE_RAW = REPO_ROOT / "data" / "005_hard_solve_raw.jsonl"


class HardConvergenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SOURCE_RAW.exists():
            raise unittest.SkipTest(f"requires Experiment 005 artifact: {SOURCE_RAW}")
        if not RAW_PATH.exists() or not TIME_CSV.exists():
            subprocess.run(
                [sys.executable, str(RUNNER), "--experiment-only"],
                cwd=REPO_ROOT,
                check=True,
            )
        with RAW_PATH.open("r", encoding="utf-8") as handle:
            cls.raw_rows = [json.loads(line) for line in handle if line.strip()]
        cls.time_rows = read_csv(TIME_CSV)
        cls.token_rows = read_csv(TOKENS_CSV)
        cls.attempt_rows = read_csv(ATTEMPTS_CSV)

    def test_raw_rows_include_budget_stop_information(self) -> None:
        required = {
            "method",
            "example_id",
            "seed",
            "budget_type",
            "budget",
            "outcome",
            "stopped_by_budget",
            "resource_value",
        }
        self.assertGreater(len(self.raw_rows), 0)
        for row in self.raw_rows:
            self.assertTrue(required.issubset(row))

    def test_curves_cover_required_methods_and_budgets(self) -> None:
        methods = {"ours_hard", "guidance_hard", "outlines_hard"}
        self.assertEqual({row["method"] for row in self.time_rows}, methods)
        self.assertEqual({float(row["budget"]) for row in self.time_rows}, {500, 1000, 2000, 5000, 10000})
        self.assertEqual({float(row["budget"]) for row in self.token_rows}, {64, 128, 256, 512})
        self.assertEqual({float(row["budget"]) for row in self.attempt_rows}, {1, 2, 4, 8})

    def test_each_method_has_at_least_five_seeds(self) -> None:
        for rows in [self.time_rows, self.token_rows, self.attempt_rows]:
            for row in rows:
                self.assertGreaterEqual(int(row["seed_count"]), 5)

    def test_found_wrong_is_preserved_as_separate_outcome(self) -> None:
        for rows in [self.time_rows, self.token_rows, self.attempt_rows]:
            for row in rows:
                self.assertIn("WrongRate", row)
                self.assertIn("FOUND_WRONG", row)

    def test_png_figures_exist_and_have_png_header(self) -> None:
        for name in ["006_hard_solve_by_time.png", "006_hard_solve_by_tokens.png"]:
            path = FIGURES_DIR / name
            self.assertTrue(path.exists(), name)
            self.assertEqual(path.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")


def read_csv(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


if __name__ == "__main__":
    unittest.main()
