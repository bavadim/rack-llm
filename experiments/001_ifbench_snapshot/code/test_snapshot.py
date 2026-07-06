#!/usr/bin/env python3
"""Validation tests for the pinned IFBench snapshot artifact."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
SNAPSHOT_PATH = EXPERIMENT_DIR / "data" / "ifbench_snapshot.jsonl"
META_PATH = EXPERIMENT_DIR / "data" / "ifbench_snapshot_meta.json"
BUILD_SCRIPT = EXPERIMENT_DIR / "code" / "build_snapshot.py"

sys.path.insert(0, str(EXPERIMENT_DIR / "code"))
import build_snapshot  # noqa: E402


class SnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not SNAPSHOT_PATH.exists() or not META_PATH.exists():
            subprocess.run(
                [sys.executable, str(BUILD_SCRIPT), "--experiment-only"],
                cwd=REPO_ROOT,
                check=True,
            )
        cls.rows = []
        with SNAPSHOT_PATH.open("r", encoding="utf-8") as handle:
            for line in handle:
                cls.rows.append(json.loads(line))
        with META_PATH.open("r", encoding="utf-8") as handle:
            cls.meta = json.load(handle)

    def test_snapshot_jsonl_is_valid(self) -> None:
        self.assertGreater(len(self.rows), 0)
        for row in self.rows:
            self.assertIsInstance(row, dict)

    def test_required_fields_present(self) -> None:
        required = {
            "key",
            "prompt",
            "instruction_id_list",
            "kwargs",
            "raw_row_sha256",
        }
        for row in self.rows:
            self.assertTrue(required.issubset(row))
            self.assertIsInstance(row["instruction_id_list"], list)
            self.assertIsInstance(row["kwargs"], list)

    def test_registry_coverage(self) -> None:
        registry_source = build_snapshot.fetch_text(
            f"{build_snapshot.RAW_BASE_URL}/{build_snapshot.REGISTRY_FILE}"
        )
        registry_ids = build_snapshot.parse_registry_ids(registry_source)
        snapshot_ids = {
            instruction_id
            for row in self.rows
            for instruction_id in row["instruction_id_list"]
        }
        self.assertTrue(snapshot_ids)
        self.assertFalse(snapshot_ids - registry_ids)
        self.assertEqual(len(snapshot_ids), self.meta["num_unique_instruction_ids"])

    def test_hash_stable(self) -> None:
        raw_jsonl = build_snapshot.fetch_text(
            f"{build_snapshot.RAW_BASE_URL}/{build_snapshot.SOURCE_FILE}"
        )
        rebuilt, _meta = build_snapshot.build_snapshot(
            raw_jsonl,
            build_snapshot.fetch_text(
                f"{build_snapshot.RAW_BASE_URL}/{build_snapshot.REGISTRY_FILE}"
            ),
        )
        self.assertEqual(
            [row["raw_row_sha256"] for row in rebuilt],
            [row["raw_row_sha256"] for row in self.rows],
        )

    def test_meta_counts_match_snapshot(self) -> None:
        unique_ids = {
            instruction_id
            for row in self.rows
            for instruction_id in row["instruction_id_list"]
        }
        self.assertEqual(self.meta["num_rows"], len(self.rows))
        self.assertEqual(self.meta["num_unique_instruction_ids"], len(unique_ids))

    def test_root_copy_matches_experiment_copy_when_present(self) -> None:
        root_snapshot = REPO_ROOT / "data" / "ifbench_snapshot.jsonl"
        if not root_snapshot.exists():
            self.skipTest("root data copy is optional for isolated experiment tests")
        self.assertEqual(
            hashlib.sha256(SNAPSHOT_PATH.read_bytes()).hexdigest(),
            hashlib.sha256(root_snapshot.read_bytes()).hexdigest(),
        )


if __name__ == "__main__":
    unittest.main()
