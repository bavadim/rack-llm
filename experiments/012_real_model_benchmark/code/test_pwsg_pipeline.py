from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DATASET = ROOT / "data" / "012_pwsg_specs.jsonl"


class PwsgDatasetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rows = [json.loads(line) for line in DATASET.read_text(encoding="utf-8").splitlines() if line]

    def test_dataset_has_paper_scale_coverage(self) -> None:
        self.assertGreaterEqual(len(self.rows), 150)
        self.assertEqual(len({row["key"] for row in self.rows}), len(self.rows))

    def test_every_noise_level_has_structural_rules(self) -> None:
        for row in self.rows:
            for noise in ("clean", "noisy_20", "noisy_40"):
                rules = row["rule_sets"][noise]
                weak = [rule for rule in rules if rule["polarity"] != "ban"]
                self.assertGreaterEqual(len(weak), 3)
                self.assertEqual({rule["matcher"] for rule in rules}, {"literal"})
                self.assertTrue({rule["polarity"] for rule in weak} <= {"prefer", "avoid"})
                self.assertTrue(any(rule["polarity"] == "ban" for rule in rules))

    def test_noise_changes_evidence_without_changing_rows(self) -> None:
        for row in self.rows:
            clean = row["rule_sets"]["clean"]
            self.assertNotEqual(clean, row["rule_sets"]["noisy_20"])
            self.assertNotEqual(clean, row["rule_sets"]["noisy_40"])


if __name__ == "__main__":
    unittest.main()
