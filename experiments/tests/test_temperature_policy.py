from __future__ import annotations

import unittest

from pwseq_experiments import pipeline
from pwseq_experiments.common import EXPERIMENTS


class CalibrationPolicyTests(unittest.TestCase):
    def test_frozen_policy_uses_one_distribution_and_twenty_candidates(self):
        policy = pipeline.temperature_policy()
        self.assertEqual(policy, {
            "primary_temperature": 1.0,
            "primary_calibration_seeds": list(range(20)),
            "candidate_evaluation_seeds": list(range(20)),
        })

    def test_seed_cardinalities_are_not_tunable(self):
        config = pipeline.load_config()
        changed = {**config, "candidate_evaluation_seeds": list(range(19))}
        with self.assertRaisesRegex(ValueError, "fixes calibration/evaluation seeds"):
            pipeline.temperature_policy(changed)

    def test_primary_posterior_policy_is_not_tunable(self):
        config = pipeline.load_config()
        changed = {
            **config,
            "posterior_policy": {"good_multiplier": 20.0, "bad_multiplier": 1.0},
        }
        with self.assertRaisesRegex(ValueError, "good=1, bad=0"):
            pipeline.temperature_policy(changed)

    def test_deprecated_filter_and_temperature_ablation_are_not_executed(self):
        sources = [
            (EXPERIMENTS / "src" / "pwseq_experiments" / name).read_text()
            for name in ("pipeline.py", "run.py", "analysis.py")
        ]
        source = "\n".join(sources)
        for forbidden in (
            "technical_filter", "enforce_technical_gate", "selected_slots",
            "fit_temperature_ablation", "temperature_ablation_report",
            "mixture_0p7_1p0", "rule_audit_temperatures",
        ):
            self.assertNotIn(forbidden, source)

    def test_schema_id_binds_dataset_family_and_noise(self):
        clean = pipeline.rule_schema_id("format:list", 0.0)
        noisy = pipeline.rule_schema_id("format:list", 0.2)
        other = pipeline.rule_schema_id("format:quotes", 0.0)
        self.assertNotEqual(clean, noisy)
        self.assertNotEqual(clean, other)
        self.assertRegex(clean, r"pwseq-ifbench/.+/format:list/noise-00@1$")

    def test_score_errors_remain_explicit_without_posterior_fallback(self):
        rows = pipeline._score_rows_with_explicit_calibration_status([{
            "record_type": "score_error", "candidate_id": "candidate",
            "family": "family", "labels": [1, 0, -1], "message": "failed",
        }])
        self.assertEqual(rows[0]["record_type"], "score")
        self.assertEqual(rows[0]["calibration_status"], "ERROR")
        self.assertIsNone(rows[0]["posterior"])
        self.assertEqual(rows[0]["labels"], [1, 0, -1])


if __name__ == "__main__":
    unittest.main()
