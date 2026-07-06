#!/usr/bin/env python3
"""Validation tests for IFBench constraint classification."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
MAP_PATH = EXPERIMENT_DIR / "data" / "ifbench_constraint_map.json"
SNAPSHOT_PATH = REPO_ROOT / "data" / "ifbench_snapshot.jsonl"
BUILD_SCRIPT = EXPERIMENT_DIR / "code" / "build_constraint_map.py"


class ConstraintMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not MAP_PATH.exists():
            subprocess.run(
                [sys.executable, str(BUILD_SCRIPT), "--experiment-only"],
                cwd=REPO_ROOT,
                check=True,
            )
        with SNAPSHOT_PATH.open("r", encoding="utf-8") as handle:
            cls.rows = [json.loads(line) for line in handle if line.strip()]
        with MAP_PATH.open("r", encoding="utf-8") as handle:
            cls.constraint_map = json.load(handle)

    def test_all_ids_classified(self) -> None:
        snapshot_ids = {
            instruction_id
            for row in self.rows
            for instruction_id in row["instruction_id_list"]
        }
        self.assertEqual(snapshot_ids, set(self.constraint_map))

    def test_no_empty_reason(self) -> None:
        for instruction_id, item in self.constraint_map.items():
            self.assertIsInstance(item["reason"], str, instruction_id)
            self.assertTrue(item["reason"].strip(), instruction_id)

    def test_hard_builders_named(self) -> None:
        hard_items = [
            item for item in self.constraint_map.values() if item["hard_supported"]
        ]
        self.assertTrue(hard_items)
        for item in hard_items:
            self.assertIsInstance(item["hard_builder"], str)
            self.assertTrue(item["hard_builder"].startswith("build_hard_"))

    def test_soft_builders_named(self) -> None:
        soft_items = [
            item for item in self.constraint_map.values() if item["soft_supported"]
        ]
        self.assertTrue(soft_items)
        for item in soft_items:
            self.assertIsInstance(item["soft_builder"], str)
            self.assertTrue(item["soft_builder"].startswith("build_soft_"))

    def test_snapshot_counts_match(self) -> None:
        counts = {}
        for row in self.rows:
            for instruction_id in row["instruction_id_list"]:
                counts[instruction_id] = counts.get(instruction_id, 0) + 1
        for instruction_id, count in counts.items():
            self.assertEqual(
                self.constraint_map[instruction_id]["snapshot_count"],
                count,
                instruction_id,
            )


if __name__ == "__main__":
    unittest.main()
