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
    def test_candidate_protocol_fixes_calibration_and_dev_to_twenty_each(self):
        calibration = {"id": "cal", "family": "family", "split": "calibration"}
        dev = {"id": "dev", "family": "family", "split": "dev"}
        candidates = [
            *[_candidate(calibration, 1.0, seed) for seed in range(20)],
            *[_candidate(dev, 1.0, seed) for seed in range(20)],
        ]
        report = run.design_candidate_protocol_report([calibration, dev], candidates)
        self.assertTrue(report["passed"])
        self.assertEqual(report["expected_candidates"], 40)

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

    def test_design_records_gold_support_but_does_not_use_it_as_a_gate(self):
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
            mock.patch.object(
                run, "generate_pool", side_effect=[pool, RuntimeError("stop after design")]
            ),
            mock.patch.object(
                run, "design_candidate_protocol_report", return_value={"passed": True}
            ),
            mock.patch.object(run, "write_json"),
            mock.patch.object(
                run, "observe", side_effect=lambda *_args, **_kwargs: events.append("observe") or Path("obs")
            ),
            mock.patch.object(
                run, "evaluate_candidates",
                side_effect=lambda *_args: events.append("official"),
            ),
            mock.patch.object(
                run, "gold_class_support_report",
                return_value={"passed": False, "families": []},
            ),
            mock.patch.object(
                run, "fit_score",
                side_effect=lambda *_args, **_kwargs: events.append("fit")
                or (Path("instances"), Path("scores")),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "stop after design"):
                run.run_design()
        self.assertEqual(events, ["observe", "fit", "official"])

    def test_confirmatory_calibration_is_frozen_before_official_labels(self):
        events = []
        with (
            mock.patch.object(
                run, "_candidate_inputs",
                return_value=(Path("pool.jsonl"), Path("instances.jsonl")),
            ),
            mock.patch.object(run, "all_instances", return_value=[]),
            mock.patch.object(run, "apply_noise", return_value=[]),
            mock.patch.object(
                run, "fit_score",
                side_effect=lambda *_args: events.append("fit")
                or (Path("bound.jsonl"), Path("scores.jsonl")),
            ),
            mock.patch.object(
                run, "_candidate_labels",
                side_effect=lambda *_args: events.append("official")
                or Path("labels.jsonl"),
            ),
            mock.patch.object(run, "aggregation_report"),
        ):
            run.run_aggregation("main", 0.123)
        self.assertEqual(events, ["fit", "official"])

    def test_rule_audit_cannot_materialize_gold_before_calibration(self):
        events = []
        with (
            mock.patch.object(
                run, "run_aggregation",
                side_effect=lambda *_args: events.extend(["fit", "official"]),
            ),
            mock.patch.object(
                run, "_candidate_inputs",
                return_value=(Path("pool.jsonl"), Path("instances.jsonl")),
            ),
            mock.patch.object(run, "all_instances", return_value=[]),
            mock.patch.object(run, "apply_noise", return_value=[]),
            mock.patch.object(
                run, "observe",
                side_effect=lambda *_args: events.append("audit-observe")
                or Path("obs.jsonl"),
            ),
            mock.patch.object(
                run, "_candidate_labels",
                return_value=Path("labels.jsonl"),
            ),
            mock.patch.object(run, "audit_report"),
        ):
            run.run_audit("main", 0.2)
        self.assertEqual(events, ["fit", "official", "audit-observe"])

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
