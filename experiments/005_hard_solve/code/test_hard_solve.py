#!/usr/bin/env python3
"""Sanity tests for the offline hard-solve benchmark."""

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
RUNNER = EXPERIMENT_DIR / "code" / "run_hard_solve.py"
RESULTS_DIR = EXPERIMENT_DIR / "results"
RAW_PATH = RESULTS_DIR / "005_hard_solve_raw.jsonl"
SUMMARY_PATH = RESULTS_DIR / "005_hard_solve_summary.csv"
SOURCE_RAW = REPO_ROOT / "data" / "012_hard_real_raw.jsonl"


class HardSolveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SOURCE_RAW.exists():
            raise unittest.SkipTest(f"requires native hard runtime artifact: {SOURCE_RAW}")
        if not RAW_PATH.exists() or not SUMMARY_PATH.exists():
            subprocess.run(
                [sys.executable, str(RUNNER), "--experiment-only"],
                cwd=REPO_ROOT,
                check=True,
            )
        with RAW_PATH.open("r", encoding="utf-8") as handle:
            cls.raw_rows = [json.loads(line) for line in handle if line.strip()]
        with SUMMARY_PATH.open("r", encoding="utf-8", newline="") as handle:
            cls.summary_rows = list(csv.DictReader(handle))

    def test_raw_jsonl_contains_required_fields(self) -> None:
        required = {"method", "example_id", "seed", "outcome", "latency_ms", "text_hash"}
        self.assertGreater(len(self.raw_rows), 0)
        for row in self.raw_rows:
            self.assertTrue(required.issubset(row))

    def test_all_methods_share_same_examples_and_seeds(self) -> None:
        methods = {row["method"] for row in self.raw_rows}
        self.assertEqual(
            methods,
            {"ours_hard", "guidance_hard", "outlines_hard"},
        )
        expected_pairs = {
            (row["example_id"], row["seed"])
            for row in self.raw_rows
            if row["method"] == "ours_hard"
        }
        for method in methods:
            pairs = {
                (row["example_id"], row["seed"])
                for row in self.raw_rows
                if row["method"] == method
            }
            self.assertEqual(pairs, expected_pairs, method)

    def test_toy_format_options_has_no_ours_wrong(self) -> None:
        option_rows = [
            row
            for row in self.raw_rows
            if row["method"] == "ours_hard"
            and row["instruction_id_list"] == ["format:options"]
        ]
        self.assertGreaterEqual(len({row["example_id"] for row in option_rows}), 5)
        self.assertFalse([row for row in option_rows if row["outcome"] == "FOUND_WRONG"])

    def test_summary_contains_hard_outcomes(self) -> None:
        by_method = {row["method"]: row for row in self.summary_rows}
        self.assertEqual(float(by_method["ours_hard"]["WrongRate"]), 0.0)
        self.assertGreater(float(by_method["ours_hard"]["SolveRate"]), 0.0)
        self.assertNotIn("vanilla_nucleus_posthoc", by_method)


if __name__ == "__main__":
    unittest.main()
