from __future__ import annotations

import math
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


def _power_fixture(
    root: Path, *, families: tuple[str, ...] = ("a",), test_per_family: int = 7,
) -> tuple[Path, Path, dict]:
    artifacts = root / "artifacts"
    data = root / "data"
    (artifacts / "results").mkdir(parents=True)
    (artifacts / "thresholds").mkdir()
    calibration_dir = artifacts / "calibrations" / "main_design" / "noise_00"
    calibration_dir.mkdir(parents=True)
    data.mkdir()
    write_json(data / "manifest.json", {
        "experiment_revision": "test-revision", "families": list(families),
    })
    dev = [
        {"id": f"dev-{family}-{index}", "family": family}
        for family in families for index in range(2)
    ]
    test = [
        {"id": f"test-{family}-{index}", "family": family}
        for family in families for index in range(test_per_family)
    ]
    write_jsonl(data / "dev.jsonl", dev)
    write_jsonl(data / "test.jsonl", test)
    write_json(calibration_dir / "manifest.json", {
        "cohorts": {family: {"status": "OK"} for family in families},
    })
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
            prompt_index = int(prompt["id"].rsplit("-", 1)[1])
            for seed in (0, 1):
                raw.append({
                    "split": "dev", "budget": 8, "method": method,
                    "prompt_id": prompt["id"], "family": prompt["family"],
                    "seed": seed,
                    "outcome": (
                        "FOUND_OK"
                        if method == "exact_pwsg" and prompt_index == 0
                        else "FOUND_WRONG"
                    ),
                    "confidence": 1.0,
                })
    write_jsonl(
        artifacts / "results" / "main_design_noise_00_generation_raw.jsonl", raw,
    )
    config = {
        "generation_seeds": [0, 1], "power_target_effect": .05,
        "power_alpha": .05, "power_target": .8,
    }
    return artifacts, data, config


class DesignProtocolTests(unittest.TestCase):
    def _power_analysis(self, artifacts: Path, data: Path, config: dict) -> dict:
        with (
            mock.patch.object(power, "ARTIFACTS", artifacts),
            mock.patch.object(power, "DATA", data),
            mock.patch.object(power, "assert_frozen"),
            mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
            mock.patch.object(power, "load_config", return_value=config),
        ):
            return power.power_analysis()

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
            artifacts, data, config = _power_fixture(root)
            raw_path = artifacts / "results" / "main_design_noise_00_generation_raw.jsonl"
            raw = common.read_jsonl(raw_path)
            raw.append(dict(raw[0]))
            write_jsonl(raw_path, raw)
            with self.assertRaisesRegex(RuntimeError, "invalid dev seed cohort"):
                self._power_analysis(artifacts, data, config)

    def test_power_requires_exactly_complete_ok_calibration_cohorts(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, config = _power_fixture(Path(directory), families=("a", "b"))
            path = artifacts / "calibrations" / "main_design" / "noise_00" / "manifest.json"
            write_json(path, {"cohorts": {"a": {"status": "OK"}}})
            with self.assertRaisesRegex(RuntimeError, "exactly all dataset families"):
                self._power_analysis(artifacts, data, config)
            write_json(path, {"cohorts": {
                "a": {"status": "ERROR"}, "b": {"status": "OK"},
            }})
            with self.assertRaisesRegex(RuntimeError, "not all OK"):
                self._power_analysis(artifacts, data, config)

    def test_power_rejects_any_primary_method_calibration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, config = _power_fixture(Path(directory))
            path = artifacts / "results" / "main_design_noise_00_generation_raw.jsonl"
            rows = common.read_jsonl(path)
            rows.append({
                **rows[0], "budget": 4, "calibration_status": "ERROR",
            })
            write_jsonl(path, rows)
            with self.assertRaisesRegex(RuntimeError, "rejects calibration errors"):
                self._power_analysis(artifacts, data, config)

    def test_power_uses_dynamic_balanced_test_size_and_records_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            artifacts, data, config = _power_fixture(
                Path(directory), families=("a", "b"), test_per_family=7,
            )
            result = self._power_analysis(artifacts, data, config)
            self.assertEqual(result["test_prompts"], 14)
            self.assertEqual(result["prompts_per_family"], 7)
            self.assertEqual(result["test_families"], ["a", "b"])
            expected = math.ceil(
                7 * (result["minimum_detectable_effect"] / .05) ** 2 / 10
            ) * 10
            self.assertEqual(result["required_prompts_per_family"], expected)

    def test_record_design_rejects_low_power_and_binds_dynamic_dataset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts, data, config = _power_fixture(
                root, families=("a", "b"), test_per_family=7,
            )
            result = self._power_analysis(artifacts, data, config)
            config_path = root / "paper.json"
            write_json(config_path, config)
            patches = (
                mock.patch.object(power, "ARTIFACTS", artifacts),
                mock.patch.object(power, "DATA", data),
                mock.patch.object(power, "CONFIG_PATH", config_path),
                mock.patch.object(power, "assert_frozen"),
                mock.patch.object(power, "run_state", return_value="DESIGN_COMPLETE"),
                mock.patch.object(power, "load_config", return_value=config),
                mock.patch.object(power, "set_run_state"),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6]:
                with self.assertRaisesRegex(RuntimeError, "below required"):
                    power.record_design()
                result["achieved_power"] = config["power_target"]
                result["target_effect"] = .10
                write_json(artifacts / "design" / "power_mde.json", result)
                with self.assertRaisesRegex(RuntimeError, "power-protocol mismatch"):
                    power.record_design()
                result["target_effect"] = config["power_target_effect"]
                write_json(artifacts / "design" / "power_mde.json", result)
                design = power.record_design()
            self.assertEqual(design["frozen_test_prompts"], 14)
            self.assertEqual(design["frozen_test_prompts_per_family"], 7)
            self.assertEqual(design["frozen_test_families"], ["a", "b"])
            self.assertEqual(design["dataset_revision"], "test-revision")
            with (
                mock.patch.object(run, "DATA", data),
                mock.patch.object(
                    run, "load_config", return_value={"confirmatory_design": design},
                ),
            ):
                self.assertEqual(run.require_confirmatory_design(), design)
            test_rows = common.read_jsonl(data / "test.jsonl")
            test_rows[0]["id"] = "changed-after-design"
            write_jsonl(data / "test.jsonl", test_rows)
            with (
                mock.patch.object(run, "DATA", data),
                mock.patch.object(
                    run, "load_config", return_value={"confirmatory_design": design},
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    run.require_confirmatory_design()


if __name__ == "__main__":
    unittest.main()
