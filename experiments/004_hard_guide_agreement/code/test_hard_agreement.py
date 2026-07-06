#!/usr/bin/env python3
"""Validation tests for hard-guide agreement artifacts."""

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
BUILD_SCRIPT = EXPERIMENT_DIR / "code" / "build_hard_agreement.py"
DATA_DIR = EXPERIMENT_DIR / "data"
REPORT_PATH = DATA_DIR / "hard_guide_agreement_report.csv"
SUBSET_PATH = DATA_DIR / "hard_ifbench_subset.jsonl"
FAILURES_PATH = DATA_DIR / "hard_guide_agreement_failures.jsonl"
SNAPSHOT_PATH = REPO_ROOT / "data" / "ifbench_snapshot.jsonl"


class HardAgreementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not REPORT_PATH.exists() or not SUBSET_PATH.exists() or not FAILURES_PATH.exists():
            subprocess.run(
                [sys.executable, str(BUILD_SCRIPT), "--experiment-only"],
                cwd=REPO_ROOT,
                check=True,
            )
        with SNAPSHOT_PATH.open("r", encoding="utf-8") as handle:
            cls.snapshot_rows = [json.loads(line) for line in handle if line.strip()]
        with REPORT_PATH.open("r", encoding="utf-8", newline="") as handle:
            cls.report_rows = list(csv.DictReader(handle))
        with SUBSET_PATH.open("r", encoding="utf-8") as handle:
            cls.subset_rows = [json.loads(line) for line in handle if line.strip()]
        with FAILURES_PATH.open("r", encoding="utf-8") as handle:
            cls.failure_rows = [json.loads(line) for line in handle if line.strip()]

    def test_agreement_report_has_all_rows(self) -> None:
        self.assertEqual(len(self.report_rows), len(self.snapshot_rows))
        self.assertEqual(
            {row["key"] for row in self.report_rows},
            {row["key"] for row in self.snapshot_rows},
        )

    def test_subset_only_agreed_rows(self) -> None:
        report_by_key = {row["key"]: row for row in self.report_rows}
        for row in self.subset_rows:
            report = report_by_key[row["key"]]
            self.assertEqual(report["included"], "true")
            self.assertGreaterEqual(float(report["ours_agreement"]), 0.99)
            self.assertGreaterEqual(float(report["guidance_agreement"]), 0.99)
            self.assertGreaterEqual(float(report["outlines_agreement"]), 0.99)

    def test_failures_have_reason(self) -> None:
        for row in self.failure_rows:
            self.assertTrue(row["failure_reason"].strip(), row.get("key"))

    def test_subset_rows_have_hard_agreement_metadata(self) -> None:
        for row in self.subset_rows:
            self.assertIn("hard_agreement", row)
            self.assertGreaterEqual(row["hard_agreement"]["ours"], 0.99)
            self.assertGreater(row["hard_agreement"]["validation_pool_size"], 0)


if __name__ == "__main__":
    unittest.main()
