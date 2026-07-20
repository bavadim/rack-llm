from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from pwseq_experiments import common, power
from pwseq_experiments.analysis import _accepts_threshold
from pwseq_experiments.common import write_json, write_jsonl
from pwseq_experiments.fuse import fit_fuse, predict_fuse
from pwseq_experiments.metrics import (
    calibration_bins,
    classification_metrics,
    common_coverage_metrics,
    corrected_bootstrap_p,
    normalized_partial_aurc,
    selective_curve,
)
from pwseq_experiments.pipeline import _operational_threshold
from pwseq_experiments.reporting import (
    generation_scalar_data,
    prompt_generation_records,
    reliability_data,
)


def _accepts(row: dict, decision: dict) -> bool:
    return row["confidence"] >= decision["threshold"]


def _power_fixture(
    root: Path, *, constant_effect: bool = False, degraded: bool = False,
) -> tuple[Path, Path, Path, dict]:
    artifacts, data = root / "artifacts", root / "data"
    (artifacts / "results").mkdir(parents=True)
    (artifacts / "thresholds").mkdir()
    calibration = artifacts / "calibrations" / "main_design" / "noise_00"
    calibration.mkdir(parents=True)
    data.mkdir()
    families = ["a", "b"]
    write_json(data / "manifest.json", {
        "experiment_revision": "test-revision", "families": families,
    })
    dev = [
        {"id": f"dev-{family}-{index}", "family": family}
        for family in families for index in range(2)
    ]
    test = [
        {"id": f"test-{family}-{index}", "family": family}
        for family in families for index in range(7)
    ]
    write_jsonl(data / "dev.jsonl", dev)
    write_jsonl(data / "test.jsonl", test)
    write_json(calibration / "manifest.json", {"cohorts": {
        family: {"status": "ERROR" if degraded and family == "b" else "OK"}
        for family in families
    }})
    write_jsonl(
        artifacts / "thresholds" / "main_design_noise_00.jsonl",
        [{
            "method": method, "budget": 8, "source_split": "dev",
            "accept_if": "always", "threshold": None,
        } for method in power.PRIMARY_METHODS],
    )
    raw = []
    for method in power.PRIMARY_METHODS:
        for prompt in dev:
            index = int(prompt["id"].rsplit("-", 1)[1])
            for seed in (0, 1):
                row = {
                    "split": "dev", "budget": 8, "method": method,
                    "prompt_id": prompt["id"], "family": prompt["family"],
                    "seed": seed, "confidence": 1.0,
                    "outcome": (
                        "FOUND_OK"
                        if method == "posterior_best_of_b"
                        and (constant_effect or index == 0)
                        else "FOUND_WRONG"
                    ),
                }
                if (
                    degraded
                    and prompt["family"] == "b"
                    and method == "posterior_best_of_b"
                ):
                    row["calibration_status"] = "ERROR"
                raw.append(row)
    write_jsonl(
        artifacts / "results" / "main_design_noise_00_generation_raw.jsonl", raw,
    )
    config = {
        "generation_seeds": [0, 1], "power_target_effect": .05,
        "power_alpha": .05, "power_target": .8,
    }
    config_path = root / "paper.json"
    write_json(config_path, config)
    return artifacts, data, config_path, config


def _power_analysis(artifacts: Path, data: Path, config: dict) -> dict:
    with (
        mock.patch.object(power, "ARTIFACTS", artifacts),
        mock.patch.object(power, "DATA", data),
        mock.patch.object(power, "assert_frozen"),
        mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
        mock.patch.object(power, "load_config", return_value=config),
    ):
        return power.power_analysis()


class StatisticsTests(unittest.TestCase):
    def test_candidate_metrics_and_calibration_bins(self):
        result = classification_metrics([0, 0, 1, 1], [.1, .2, .8, .9])
        self.assertAlmostEqual(result["auprc"], 1.0)
        self.assertAlmostEqual(result["auroc"], 1.0)
        self.assertLess(result["brier"], .05)
        bins = calibration_bins(
            np.asarray([0, 0, 1, 1]), np.asarray([.1, .2, .8, .9]), 2,
        )
        self.assertEqual(sum(group["count"] for group in bins), 4)

    def test_selective_metrics_share_coverage_and_respect_ties(self):
        full = selective_curve([
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "FOUND_WRONG", "confidence": .8},
            {"outcome": "FOUND_OK", "confidence": .7},
        ])
        short = selective_curve([
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "NOT_FOUND", "confidence": 0},
            {"outcome": "NOT_FOUND", "confidence": 0},
        ])
        self.assertEqual(len(full), 3)  # origin plus two distinct thresholds
        self.assertAlmostEqual(full[1]["risk"], .5)
        common = common_coverage_metrics({"full": full, "short": short})
        self.assertEqual(common["full"]["common_coverage"], 1 / 3)
        self.assertIsNone(common["short"]["risk_at_50"])
        self.assertGreaterEqual(normalized_partial_aurc(full, 1 / 3), 0)

    def test_dev_threshold_semantics_are_grouped_and_serializable(self):
        rows = [
            {"outcome": "FOUND_OK", "confidence": .9},
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "FOUND_WRONG", "confidence": .8},
            {"outcome": "NOT_FOUND", "confidence": 1.0},
        ]
        self.assertEqual(_operational_threshold(rows, .05), .9)
        self.assertFalse(
            _accepts_threshold({"confidence": 1.0}, {"accept_if": "never", "threshold": None})
        )
        self.assertTrue(
            _accepts_threshold({"confidence": 0.0}, {"accept_if": "always", "threshold": None})
        )

    def test_zero_label_fuse_recovers_informative_sources(self):
        rng = np.random.default_rng(17)
        latent = rng.integers(0, 2, size=3000)
        matrix = np.column_stack([
            np.where(rng.random(len(latent)) < accuracy, latent, 1 - latent)
            for accuracy in (.82, .75, .70, .65)
        ])
        labels = (2 * matrix - 1).tolist()
        model = fit_fuse(labels)
        self.assertEqual(model.status, "OK", model.reason)
        self.assertFalse(model.official_implementation)
        probability = predict_fuse(model, labels)
        self.assertGreater(np.corrcoef(probability, latent)[0, 1], .5)

    def test_prompt_seed_family_bootstrap_is_macro_and_deterministic(self):
        seed_rows = [
            {
                "method": "m", "budget": 8, "prompt_id": "small-0",
                "family": "small", "seed": 0, "outcome": "FOUND_OK",
                "confidence": .9, "model_draws": 2, "latency_ms": 10,
                "proposals": 1, "content_tokens": 2,
            },
            {
                "method": "m", "budget": 8, "prompt_id": "small-0",
                "family": "small", "seed": 1, "outcome": "FOUND_WRONG",
                "confidence": .4, "model_draws": 4, "latency_ms": 30,
                "proposals": 3, "content_tokens": 4,
            },
        ]
        records = prompt_generation_records(
            seed_rows, expected_seeds={0, 1},
            decisions={("m", 8): {"threshold": .5}}, accepts=_accepts,
        )
        self.assertEqual(records[0]["ok_weight"], .5)
        self.assertEqual(records[0]["wrong_weight"], 0)
        self.assertEqual(records[0]["return_weight"], .5)
        self.assertEqual(records[0]["latency_ms"], 20)
        self.assertEqual(records[0]["proposals"], 2)
        records[0]["noise"] = 0.0
        records.extend({
            **records[0], "prompt_id": f"large-{index}", "family": "large",
            "ok_weight": 0.0, "wrong_weight": 1.0, "return_weight": 1.0,
        } for index in range(3))
        first = generation_scalar_data(records, repetitions=20, confidence=.95, seed=11)
        second = generation_scalar_data(
            list(reversed(records)), repetitions=20, confidence=.95, seed=11,
        )
        self.assertEqual(first, second)
        self.assertEqual(first[0]["solve_rate"], .25)
        # Family macro: mean(0.5, 0.0), not prompt micro mean(0.5, 0, 0, 0).
        self.assertEqual(first[0]["solve_rate"], .25)
        with self.assertRaisesRegex(RuntimeError, "invalid seed cohort"):
            prompt_generation_records(seed_rows[:1], expected_seeds={0, 1})

    def test_reliability_and_bootstrap_p_are_prompt_clustered(self):
        rows = []
        gold = {}
        for family in ("a", "b"):
            for prompt in ("0", "1"):
                for sample, posterior in enumerate((.1, .4, .7, .9)):
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
        self.assertGreater(corrected_bootstrap_p([1.0] * 10_000), 0)

    def test_power_statuses_are_diagnostic_and_underpowered_designs_finalize(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, _config_path, config = _power_fixture(
                Path(directory), constant_effect=True,
            )
            adequate = _power_analysis(artifacts, data, config)
            self.assertEqual(adequate["power_status"], "ADEQUATE")
            self.assertEqual(adequate["calibration_status"], "OK")
            self.assertEqual(
                adequate["comparison"],
                "posterior_best_of_b-minus-equal_score_best_of_b",
            )
            self.assertEqual(
                adequate["metric"],
                "macro_normalized_common_coverage_paurc",
            )
            self.assertEqual(adequate["favorable_direction"], "less_than_zero")
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, config_path, config = _power_fixture(Path(directory))
            underpowered = _power_analysis(artifacts, data, config)
            self.assertEqual(underpowered["power_status"], "UNDERPOWERED")
            self.assertTrue(underpowered["power_estimable"])
            with (
                mock.patch.object(power, "ARTIFACTS", artifacts),
                mock.patch.object(power, "DATA", data),
                mock.patch.object(power, "CONFIG_PATH", config_path),
                mock.patch.object(power, "assert_frozen"),
                mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
                mock.patch.object(power, "load_config", return_value=config),
                mock.patch.object(power, "set_run_state"),
            ):
                design = power.record_design()
            self.assertEqual(design["status"], "finalized")
            self.assertEqual(design["power_status"], "UNDERPOWERED")
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, config_path, config = _power_fixture(
                Path(directory), degraded=True,
            )
            degraded = _power_analysis(artifacts, data, config)
            self.assertEqual(degraded["calibration_status"], "DEGRADED")
            self.assertEqual(degraded["calibration_problem_families"], ["b"])
            self.assertEqual(degraded["power_status"], "UNDERPOWERED")
            changed = common.read_jsonl(data / "test.jsonl")
            changed[0]["id"] = "changed-after-power"
            write_jsonl(data / "test.jsonl", changed)
            with (
                mock.patch.object(power, "ARTIFACTS", artifacts),
                mock.patch.object(power, "DATA", data),
                mock.patch.object(power, "CONFIG_PATH", config_path),
                mock.patch.object(power, "assert_frozen"),
                mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
                mock.patch.object(power, "load_config", return_value=config),
            ):
                with self.assertRaisesRegex(RuntimeError, "does not match the frozen test design"):
                    power.record_design()


if __name__ == "__main__":
    unittest.main()
