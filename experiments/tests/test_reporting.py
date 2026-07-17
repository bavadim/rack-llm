from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pwseq_experiments import analysis
from pwseq_experiments.common import read_jsonl, write_jsonl
from pwseq_experiments.reporting import (
    generation_scalar_data, prompt_generation_records, reliability_data,
)


def _accepts(row, decision):
    return row["confidence"] >= decision["threshold"]


class PromptReportingTests(unittest.TestCase):
    def test_seed_cohort_is_fail_closed_and_threshold_precedes_prompt_mean(self):
        rows = [
            {
                "method": "m", "budget": 8, "prompt_id": "p", "family": "f",
                "seed": 0, "outcome": "FOUND_OK", "confidence": .9,
                "model_draws": 2,
            },
            {
                "method": "m", "budget": 8, "prompt_id": "p", "family": "f",
                "seed": 1, "outcome": "FOUND_WRONG", "confidence": .4,
                "model_draws": 4,
            },
        ]
        records = prompt_generation_records(
            rows, expected_seeds={0, 1},
            decisions={("m", 8): {"threshold": .5}}, accepts=_accepts,
        )
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["ok_weight"], .5)
        self.assertEqual(records[0]["wrong_weight"], 0)
        self.assertEqual(records[0]["return_weight"], .5)
        self.assertEqual(records[0]["confidence"], .9)
        with self.assertRaisesRegex(RuntimeError, "invalid seed cohort"):
            prompt_generation_records(rows[:1], expected_seeds={0, 1})
        with self.assertRaisesRegex(RuntimeError, "invalid seed cohort"):
            prompt_generation_records([rows[0], rows[0]], expected_seeds={0, 1})

    def test_prompt_then_family_macro_is_not_prompt_micro_and_is_deterministic(self):
        records = [{
            "noise": 0.0, "method": "m", "budget": 8,
            "prompt_id": "a", "family": "small", "ok_weight": 1.0,
            "wrong_weight": 0.0, "return_weight": 1.0, "model_draws": 2.0,
        }]
        records.extend({
            "noise": 0.0, "method": "m", "budget": 8,
            "prompt_id": f"b{index}", "family": "large", "ok_weight": 0.0,
            "wrong_weight": 1.0, "return_weight": 1.0, "model_draws": 4.0,
        } for index in range(3))
        first = generation_scalar_data(
            records, repetitions=20, confidence=.95, seed=11,
        )
        second = generation_scalar_data(
            list(reversed(records)), repetitions=20, confidence=.95, seed=11,
        )
        self.assertEqual(first, second)
        self.assertEqual(first[0]["solve_rate"], .5)
        self.assertNotEqual(first[0]["solve_rate"], .25)
        self.assertEqual(first[0]["solve_rate_support"], 20)

    def test_scalar_reporting_rejects_unpaired_method_prompt_grids(self):
        base = {
            "noise": 0.0, "budget": 8, "family": "f", "ok_weight": 1.0,
            "wrong_weight": 0.0, "return_weight": 1.0, "model_draws": 1.0,
        }
        rows = [
            {**base, "method": "a", "prompt_id": "p0"},
            {**base, "method": "a", "prompt_id": "p1"},
            {**base, "method": "b", "prompt_id": "p0"},
        ]
        with self.assertRaisesRegex(RuntimeError, "unpaired prompt grid"):
            generation_scalar_data(rows, repetitions=5, confidence=.95, seed=1)

    def test_reliability_uses_fixed_bins_and_is_input_order_invariant(self):
        rows = []
        gold = {}
        for family in ["a", "b"]:
            for prompt in ["0", "1"]:
                for sample, posterior in enumerate([.1, .4, .7, .9]):
                    candidate = f"{family}-{prompt}-{sample}"
                    rows.append({
                        "candidate_id": candidate, "family": family,
                        "prompt_id": f"{family}-{prompt}", "posterior": posterior,
                    })
                    gold[candidate] = int(posterior >= .7)
        first = reliability_data(
            rows, gold, bins=4, repetitions=20, confidence=.95, seed=7,
        )
        second = reliability_data(
            list(reversed(rows)), gold, bins=4, repetitions=20,
            confidence=.95, seed=7,
        )
        self.assertEqual(first, second)
        self.assertEqual(sum(row["count"] for row in first), len(rows))
        self.assertTrue(all(row["bootstrap_support"] == 20 for row in first))

    def test_generation_bundle_emits_common_grid_with_ci_once(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            (artifacts / "results").mkdir()
            (artifacts / "thresholds").mkdir()
            methods = [
                "hard_only_cars", "equal_score_best_of_b",
                "posterior_best_of_b", "exact_pwsg",
            ]
            raw = []
            for method in methods:
                for family in ["a", "b"]:
                    for prompt in range(50):
                        for seed in range(5):
                            wrong = (prompt + seed + len(method)) % 11 == 0
                            raw.append({
                                "split": "test", "budget": 8, "method": method,
                                "prompt_id": f"{family}-{prompt}", "family": family,
                                "seed": seed,
                                "outcome": "FOUND_WRONG" if wrong else "FOUND_OK",
                                "confidence": .8, "model_draws": 3,
                            })
            write_jsonl(
                artifacts / "results" / "main_noise_00_generation_raw.jsonl", raw,
            )
            write_jsonl(
                artifacts / "thresholds" / "main_noise_00.jsonl",
                [{
                    "method": method, "budget": 8, "source_split": "dev",
                    "accept_if": "confidence_gte", "threshold": .5,
                } for method in methods],
            )
            config = {
                "confidence": .95, "generation_seeds": list(range(5)),
                "bootstrap_repetitions": 5, "dataset_seed": 17,
            }
            with (
                mock.patch.object(analysis, "ARTIFACTS", artifacts),
                mock.patch.object(analysis, "load_config", return_value=config),
            ):
                statistics, risk = analysis._bootstrap_generation_bundle()
            self.assertEqual(len(statistics), 3)
            self.assertGreater(len(risk), 0)
            self.assertLessEqual(len(risk), 4 * 101)
            self.assertEqual(len(risk) % 4, 0)
            self.assertTrue(all(row["bootstrap_support"] == 5 for row in risk))
            self.assertEqual({row["coverage_grid_points"] for row in risk}, {101})

    def test_png_renderer_needs_only_machine_readable_figure_data(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            figures = artifacts / "figures"
            figures.mkdir()
            write_jsonl(figures / "risk_coverage_data.jsonl", [{
                "method": "m", "coverage": 0.0, "risk": 0.0,
                "risk_ci_low": 0.0, "risk_ci_high": 0.0,
            }, {
                "method": "m", "coverage": 1.0, "risk": .1,
                "risk_ci_low": .05, "risk_ci_high": .15,
            }])
            scalar = [{
                "method": "m", "budget": 8, "noise": 0.0,
                "mean_model_tokens": 3.0, "solve_rate": .8,
                "solve_rate_ci_low": .7, "solve_rate_ci_high": .9,
                "found_wrong_rate": .1, "found_wrong_rate_ci_low": .05,
                "found_wrong_rate_ci_high": .15, "not_found_rate": .1,
                "not_found_rate_ci_low": .05, "not_found_rate_ci_high": .15,
            }]
            write_jsonl(figures / "quality_vs_budget_data.jsonl", scalar)
            write_jsonl(figures / "noise_robustness_data.jsonl", scalar)
            write_jsonl(figures / "reliability_data.jsonl", [{
                "count": 10, "mean_probability": .8, "empirical_rate": .75,
                "empirical_rate_ci_low": .6, "empirical_rate_ci_high": .9,
            }])
            with mock.patch.object(analysis, "ARTIFACTS", artifacts):
                analysis._render_figures()
            for name in [
                "risk_coverage.png", "quality_vs_budget.png",
                "noise_robustness.png", "found_wrong_vs_not_found.png",
                "reliability.png",
            ]:
                self.assertTrue((figures / name).is_file(), name)


if __name__ == "__main__":
    unittest.main()
