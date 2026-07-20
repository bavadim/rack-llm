from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pwseq_experiments import analysis, archive
from pwseq_experiments.common import write_jsonl
from pwseq_experiments.reporting import generation_scalar_data


class ReportingTests(unittest.TestCase):
    def test_hard_quality_bootstrap_is_paired_and_backend_failures_block(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            (artifacts / "hard").mkdir()
            rows = []
            for method in ("cars", "guidance", "outlines"):
                for family in ("a", "b"):
                    for prompt in range(3):
                        for seed in (0, 1):
                            rows.append({
                                "method": method, "family": family,
                                "prompt_id": f"{family}-{prompt}", "seed": seed,
                                "status": "found", "outcome": "FOUND_OK",
                            })
            write_jsonl(
                artifacts / "hard" / "hard_sanity_evaluated.jsonl", rows,
            )
            config = {
                "generation_seeds": [0, 1], "bootstrap_repetitions": 20,
                "confidence": .95, "dataset_seed": 3,
            }
            with (
                mock.patch.object(analysis, "ARTIFACTS", artifacts),
                mock.patch.object(analysis, "load_config", return_value=config),
            ):
                complete = analysis._bootstrap_hard_quality()
                failed = list(rows)
                failed[-1] = {
                    **failed[-1], "status": "backend-error",
                    "outcome": "BACKEND_ERROR",
                }
                write_jsonl(
                    artifacts / "hard" / "hard_sanity_evaluated.jsonl", failed,
                )
                blocked = analysis._bootstrap_hard_quality()
        self.assertEqual({row["difference_mean"] for row in complete}, {0.0})
        self.assertTrue(all(row["ci_low"] == 0.0 for row in complete))
        by_comparison = {row["comparison"]: row for row in blocked}
        self.assertEqual(
            by_comparison["cars-minus-outlines"]["inference_status"], "BLOCKED",
        )
        self.assertEqual(
            by_comparison["cars-minus-guidance"]["inference_status"], "ADEQUATE",
        )

    def test_archive_rejects_inconsistent_bootstrap_support_status(self):
        base = {
            "bootstrap_repetitions": 100,
            "blocked_families": [],
        }
        valid = [
            {**base, "bootstrap_support": 0, "inference_status": "BLOCKED"},
            {**base, "bootstrap_support": 94, "inference_status": "LOW_SUPPORT"},
            {**base, "bootstrap_support": 95, "inference_status": "ADEQUATE"},
            {
                **base, "bootstrap_support": 100, "inference_status": "BLOCKED",
                "blocked_families": ["family"],
            },
        ]
        for row in valid:
            archive._validate_inference_row("quality_vs_budget_data.jsonl", row)
        invalid = [
            {**base, "bootstrap_support": -1, "inference_status": "BLOCKED"},
            {**base, "bootstrap_support": 101, "inference_status": "ADEQUATE"},
            {**base, "bootstrap_support": 0, "inference_status": "LOW_SUPPORT"},
            {**base, "bootstrap_support": 94, "inference_status": "ADEQUATE"},
            {**base, "bootstrap_support": 100, "inference_status": "LOW_SUPPORT"},
        ]
        for row in invalid:
            with self.assertRaises(RuntimeError):
                archive._validate_inference_row("quality_vs_budget_data.jsonl", row)
        risk = {
            **base, "bootstrap_support": 80, "bootstrap_support_fraction": .7,
            "inference_status": "LOW_SUPPORT",
        }
        with self.assertRaisesRegex(RuntimeError, "support fraction"):
            archive._validate_inference_row("risk_coverage_data.jsonl", risk)

    def test_macro_aggregation_keeps_scientific_failure_rows_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "aggregation.jsonl"
            write_jsonl(report, [
                {
                    "split": "test", "aggregator": "weak", "family": "a",
                    "auprc": .8, "auroc": .7, "nll": .4, "brier": .2, "ece": .1,
                },
                {
                    "split": "test", "aggregator": "weak", "family": "b",
                    "auprc": .6, "auroc": .5, "nll": .6, "brier": .4, "ece": .3,
                },
                {
                    "split": "test", "aggregator": "fuse", "family": "c",
                    "status": "ERROR", "reason": "uninformative cohort",
                },
            ])
            rows = analysis._macro_aggregation(report)
        weak = next(row for row in rows if row["aggregator"] == "weak")
        blocked = next(row for row in rows if row["aggregator"] == "fuse")
        self.assertAlmostEqual(weak["auprc"], .7)
        self.assertEqual(weak["families"], 2)
        self.assertEqual(blocked["status"], "ERROR")
        self.assertEqual(blocked["reason"], "uninformative cohort")

    def test_scalar_reporting_requires_a_paired_prompt_grid(self):
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

    def test_aggregation_calibration_errors_block_inference_status(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            (artifacts / "scores").mkdir()
            (artifacts / "labels").mkdir()
            labels, scores = [], []
            for family in ("a", "b"):
                for prompt in range(4):
                    candidate = f"{family}-{prompt}"
                    gold = prompt % 2
                    labels.append({"candidate_id": candidate, "gold_pass": gold})
                    scores.append({
                        "record_type": "score", "split": "test",
                        "candidate_id": candidate, "prompt_id": candidate,
                        "family": family, "labels": [1 if gold else -1],
                        "posterior": None if candidate == "a-0" else (.8 if gold else .2),
                    })
            write_jsonl(artifacts / "scores" / "main_noise_00.jsonl", scores)
            write_jsonl(artifacts / "labels" / "main_candidate_labels.jsonl", labels)
            config = {"confidence": .95, "bootstrap_repetitions": 5, "dataset_seed": 3}
            with (
                mock.patch.object(analysis, "ARTIFACTS", artifacts),
                mock.patch.object(analysis, "load_config", return_value=config),
            ):
                rows = analysis._bootstrap_aggregation()
        self.assertTrue(all(row["inference_status"] == "BLOCKED" for row in rows))
        self.assertEqual({tuple(row["blocked_families"]) for row in rows}, {("a",)})

    def test_generation_bundle_emits_prompt_level_ci_and_machine_status(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts = Path(directory)
            (artifacts / "results").mkdir()
            (artifacts / "thresholds").mkdir()
            methods = [
                "hard_only_cars", "lm_best_of_b", "equal_score_best_of_b",
                "posterior_best_of_b", "exact_pwsg",
            ]
            raw = []
            for method in methods:
                for family in ("a", "b"):
                    for prompt in range(6):
                        for seed in (0, 1):
                            wrong = (prompt + seed + len(method)) % 7 == 0
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
                "confidence": .95, "generation_seeds": [0, 1],
                "bootstrap_repetitions": 5, "dataset_seed": 17,
            }
            with (
                mock.patch.object(analysis, "ARTIFACTS", artifacts),
                mock.patch.object(analysis, "load_config", return_value=config),
            ):
                statistics, risk = analysis._bootstrap_generation_bundle()
                degraded = list(raw)
                failed = next(
                    index for index, row in enumerate(degraded)
                    if row["method"] == "exact_pwsg"
                )
                degraded[failed] = {
                    **degraded[failed], "calibration_status": "ERROR",
                }
                write_jsonl(
                    artifacts / "results" / "main_noise_00_generation_raw.jsonl",
                    degraded,
                )
                blocked_statistics, _ = analysis._bootstrap_generation_bundle()
        self.assertEqual(len(statistics), 5)
        self.assertTrue(any(
            row["comparison"] == "equal_score_best_of_b-minus-lm_best_of_b"
            and row["role"] == "fixed_soft_primary"
            for row in statistics
        ))
        self.assertTrue(any(
            row["comparison"] == (
                "posterior_best_of_b-minus-equal_score_best_of_b"
            ) and row["role"] == "weak_generation_primary"
            for row in statistics
        ))
        self.assertTrue(any(
            row["comparison"].endswith("posterior_best_of_b") for row in statistics
        ))
        self.assertTrue(all(row["inference_status"] == "ADEQUATE" for row in statistics))
        self.assertEqual({row["bootstrap_support"] for row in risk}, {5})
        self.assertEqual({row["coverage_grid_points"] for row in risk}, {101})
        self.assertTrue(all("risk_ci_low" in row and "risk_ci_high" in row for row in risk))
        raw_records = analysis.prompt_generation_records(raw, expected_seeds={0, 1})
        grouped = {(row["method"], row["prompt_id"]): row for row in raw_records}
        prompts = {item["prompt_id"] for item in raw_records}
        for row in statistics:
            ours, baseline = row["comparison"].split("-minus-", 1)
            expected_solve = sum(
                grouped[(ours, prompt)]["ok_weight"]
                - grouped[(baseline, prompt)]["ok_weight"]
                for prompt in prompts
            ) / len(prompts)
            self.assertAlmostEqual(
                row["solve_rate_difference_mean"], expected_solve,
            )
            family_paurc = []
            for family in ("a", "b"):
                family_prompts = sorted(
                    prompt for prompt in prompts if prompt.startswith(f"{family}-")
                )
                common = analysis.common_coverage_metrics({
                    method: analysis.selective_curve([
                        grouped[(method, prompt)] for prompt in family_prompts
                    ]) for method in (ours, baseline)
                })
                family_paurc.append(
                    common[ours]["normalized_partial_aurc"]
                    - common[baseline]["normalized_partial_aurc"]
                )
            expected_paurc = sum(family_paurc) / len(family_paurc)
            self.assertAlmostEqual(row["paurc_difference_mean"], expected_paurc)
        blocked_by_comparison = {
            row["comparison"]: row for row in blocked_statistics
        }
        self.assertEqual(
            blocked_by_comparison[
                "exact_pwsg-minus-posterior_best_of_b"
            ]["inference_status"],
            "BLOCKED",
        )
        self.assertEqual(
            blocked_by_comparison[
                "equal_score_best_of_b-minus-lm_best_of_b"
            ]["inference_status"],
            "ADEQUATE",
        )

    def test_png_renderer_consumes_only_machine_readable_figure_data(self):
        plot = mock.Mock()
        analysis._errorbar(plot, [{
            "x": 1.0, "y": .5, "y_ci_low": None, "y_ci_high": None,
        }], "x", "y", label="point")
        plot.errorbar.assert_called_once()
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
            for name in (
                "risk_coverage.png", "quality_vs_budget.png",
                "noise_robustness.png", "found_wrong_vs_not_found.png",
                "reliability.png",
            ):
                self.assertTrue((figures / name).is_file(), name)


if __name__ == "__main__":
    unittest.main()
