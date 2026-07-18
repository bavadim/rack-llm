from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pwseq_experiments import common, pipeline, power, run
from pwseq_experiments.common import write_json, write_jsonl


def _candidate(prompt: dict, temperature: float, seed: int) -> dict:
    return {
        "candidate_id": f"{prompt['id']}-{temperature}-{seed}",
        "prompt_id": prompt["id"], "family": prompt["family"],
        "split": prompt["split"], "temperature": temperature,
        "seed": seed, "sample_index": 0,
        "status": "found", "hard_valid": True,
    }


class DesignProtocolTests(unittest.TestCase):
    def test_candidate_protocol_fixes_all_three_seed_cohorts(self):
        calibration = {"id": "cal", "family": "family", "split": "calibration"}
        dev = {"id": "dev", "family": "family", "split": "dev"}
        candidates = [
            *[_candidate(calibration, 1.0, seed) for seed in range(20)],
            *[_candidate(calibration, 0.7, seed) for seed in range(8)],
            *[_candidate(dev, 1.0, seed) for seed in range(8)],
        ]
        report = run.design_candidate_protocol_report([calibration, dev], candidates)
        self.assertTrue(report["passed"])
        self.assertEqual(report["expected_candidates"], 36)

        missing = run.design_candidate_protocol_report(
            [calibration, dev], candidates[:-1]
        )
        self.assertFalse(missing["passed"])
        self.assertEqual(missing["missing"], 1)

        invalid = [dict(row) for row in candidates]
        invalid[0]["status"] = "not-found"
        invalid[0]["hard_valid"] = False
        self.assertFalse(
            run.design_candidate_protocol_report([calibration, dev], invalid)["passed"]
        )

    def test_four_percent_filter_uses_frozen_expected_cohort(self):
        rows = []
        observations = []
        index = 0
        for prompt in range(30):
            rows.append({
                "id": f"p-{prompt}", "family": "family", "split": "calibration",
                "weak_rules": [{"slot": 0, "polarity": "positive", "pattern": "x"}],
            })
            for seed in range(20):
                observations.append({
                    "record_type": "observation", "prompt_id": f"p-{prompt}",
                    "family": "family", "split": "calibration", "seed": seed,
                    "sample_index": 0, "temperature": 1.0,
                    "labels": [1 if index < 23 else 0], "rule_ids": ["r0"],
                })
                index += 1
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            write_jsonl(path, observations)
            with mock.patch.object(
                pipeline, "ere_compiles_many", return_value=[True]
            ):
                selected, report = pipeline.technical_filter(rows, path)
        self.assertEqual(selected, {"family": []})
        self.assertEqual(report[0]["minimum_fires"], 24)
        self.assertEqual(report[0]["calibration_candidates"], 600)
        self.assertEqual(report[0]["observed_candidates"], 600)
        self.assertEqual(report[0]["reason"], "fewer_than_4pct_fires")

    def test_unlabeled_gate_rejects_incomplete_observation_cohort(self):
        rules = [
            {"slot": slot, "polarity": "positive" if slot < 3 else "negative",
             "pattern": f"p{slot}"}
            for slot in range(5)
        ]
        rows = [{
            "id": "p", "family": "family", "split": "calibration",
            "weak_rules": rules,
        }]
        observations = []
        for seed in range(20):
            observations.append({
                "record_type": "observation", "prompt_id": "p",
                "family": "family", "split": "calibration", "seed": seed,
                "sample_index": 0, "temperature": 1.0,
                "labels": [1, 0, 0, -1, 0] if seed == 0 else [0] * 5,
                "rule_ids": [f"r{slot}" for slot in range(5)],
            })
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            write_jsonl(path, observations)
            pipeline.enforce_technical_gate(rows, path, {"family": list(range(5))})
            write_jsonl(path, observations[:-1])
            with self.assertRaisesRegex(RuntimeError, "unlabeled technical rule gate"):
                pipeline.enforce_technical_gate(
                    rows, path, {"family": list(range(5))}
                )

    def test_official_labels_are_not_called_when_unlabeled_gate_fails(self):
        calibration = {"id": "cal", "family": "family", "split": "calibration"}
        dev = {"id": "dev", "family": "family", "split": "dev"}
        pool = Path("candidate-pool.jsonl")

        def fake_read(path: Path):
            if path == pool:
                return []
            return [calibration] if path.name == "calibration.jsonl" else [dev]

        events = []
        with (
            mock.patch.object(run, "read_jsonl", side_effect=fake_read),
            mock.patch.object(run, "generate_pool", return_value=pool),
            mock.patch.object(
                run, "design_candidate_protocol_report", return_value={"passed": True}
            ),
            mock.patch.object(run, "write_json"),
            mock.patch.object(
                run, "observe", side_effect=lambda *_args, **_kwargs: events.append("observe") or Path("obs")
            ),
            mock.patch.object(
                run, "technical_filter",
                side_effect=lambda *_args: events.append("filter") or ({"family": []}, []),
            ),
            mock.patch.object(
                run, "enforce_technical_gate",
                side_effect=lambda *_args: events.append("gate") or (_ for _ in ()).throw(RuntimeError("gate")),
            ),
            mock.patch.object(
                run, "evaluate_candidates",
                side_effect=lambda *_args: events.append("official"),
            ) as official,
        ):
            with self.assertRaisesRegex(RuntimeError, "gate"):
                run.run_design()
        self.assertEqual(events, ["observe", "filter", "gate"])
        official.assert_not_called()

    def test_every_test_reading_stage_requires_finalized_design(self):
        with (
            mock.patch.object(run, "assert_frozen"),
            mock.patch.object(run, "preflight", return_value={"full_ok": True}),
            mock.patch.object(run, "load_config", return_value={}),
            mock.patch.object(run, "run_aggregation") as aggregation,
        ):
            with self.assertRaisesRegex(RuntimeError, "finalized dev-only design"):
                run.run_stage("aggregation")
        aggregation.assert_not_called()

    def test_interrupt_marks_design_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "RUN_STATE.json"
            write_json(state, {"run_id": "test", "state": "FROZEN"})
            with (
                mock.patch.object(common, "STATE_FILE", state),
                mock.patch.object(run, "assert_frozen"),
                mock.patch.object(run, "preflight", return_value={"full_ok": True}),
                mock.patch.object(run, "run_design", side_effect=KeyboardInterrupt()),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    run.run_stage("design")
                self.assertEqual(common.run_state(), "FAILED")

    def test_power_rejects_duplicate_seed_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / "artifacts"
            data = root / "data"
            (artifacts / "results").mkdir(parents=True)
            (artifacts / "thresholds").mkdir()
            data.mkdir()
            write_jsonl(data / "dev.jsonl", [{"id": "p", "family": "family"}])
            write_jsonl(data / "test.jsonl", [])
            thresholds = [
                {"method": method, "budget": 8, "source_split": "dev",
                 "accept_if": "always", "threshold": None}
                for method in ("exact_pwsg", "posterior_best_of_b")
            ]
            write_jsonl(artifacts / "thresholds" / "main_design_noise_00.jsonl", thresholds)
            raw = []
            for method, seeds in (
                ("exact_pwsg", [0, 0, 1]),
                ("posterior_best_of_b", [0, 1]),
            ):
                for seed in seeds:
                    raw.append({
                        "split": "dev", "budget": 8, "method": method,
                        "prompt_id": "p", "family": "family", "seed": seed,
                        "outcome": "FOUND_OK", "confidence": 1.0,
                    })
            write_jsonl(artifacts / "results" / "main_design_noise_00_generation_raw.jsonl", raw)
            config = {
                "generation_seeds": [0, 1], "power_target_effect": .05,
                "power_alpha": .05, "power_target": .8,
            }
            with (
                mock.patch.object(power, "ARTIFACTS", artifacts),
                mock.patch.object(power, "DATA", data),
                mock.patch.object(power, "assert_frozen"),
                mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
                mock.patch.object(power, "load_config", return_value=config),
            ):
                with self.assertRaisesRegex(RuntimeError, "invalid dev seed cohort"):
                    power.power_analysis()


if __name__ == "__main__":
    unittest.main()
