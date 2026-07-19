from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from pwseq_experiments import postmortem
from pwseq_experiments.common import file_hash, stable_json


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(stable_json(row) + "\n" for row in rows), encoding="utf-8")


def _fixture(root: Path, run_id: str) -> tuple[Path, list[dict]]:
    source = root / run_id
    instances = []
    candidates = []
    observations = []
    for family_index in range(12):
        family = f"family-{family_index:02d}"
        rules = [{
            "slot": slot, "source_slot": slot,
            "rule_id": f"{family}-rule-{slot}",
            "polarity": "positive" if slot < 6 else "negative",
            "pattern": f"pattern-{slot}",
        } for slot in range(10)]
        for split, prompts in (("calibration", 30), ("dev", 10)):
            for prompt_index in range(prompts):
                prompt_id = f"{split}-{family}-{prompt_index:03d}"
                instance = {
                    "id": prompt_id, "family": family, "split": split,
                    "prompt": f"prompt {prompt_id}", "max_tokens": 100,
                    "instruction_id_list": ["test"], "kwargs": [{}],
                    "weak_rules": rules,
                }
                instances.append(instance)
                protocols = (
                    ((1.0, range(20)), (0.7, range(8)))
                    if split == "calibration" else ((1.0, range(8)),)
                )
                for temperature, seeds in protocols:
                    for seed in seeds:
                        good = seed % 2 == 0
                        candidate = {
                            "prompt_id": prompt_id, "family": family,
                            "split": split, "temperature": temperature,
                            "seed": seed, "sample_index": 0,
                            "status": "found", "hard_valid": True,
                            "text": "good response" if good else "bad response",
                            "token_ids": [seed + 1], "token_count": 10,
                            "model_family": "test-model",
                        }
                        candidate["candidate_id"] = postmortem._candidate_id(candidate)
                        candidates.append(candidate)
                        labels = []
                        for slot in range(10):
                            if slot < 6:
                                labels.append(1 if (seed + slot) % 3 == 0 else 0)
                            else:
                                labels.append(-1 if (seed + slot) % 3 == 0 else 0)
                        observations.append({
                            "record_type": "observation",
                            "candidate_id": candidate["candidate_id"],
                            "prompt_id": prompt_id, "family": family,
                            "split": split, "temperature": temperature,
                            "seed": seed, "sample_index": 0,
                            "rule_ids": [rule["rule_id"] for rule in rules],
                            "labels": labels,
                        })
    _write_json(source / "frozen_manifest.json", {
        "run_id": run_id, "ifbench_revision": "test", "external_files": {},
    })
    _write_json(source / "RUN_STATE.json", {
        "run_id": run_id, "state": "FAILED", "failed": ["design"],
    })
    _write_json(source / "reports/main_design_noise_00_filter.json", {
        "selected_slots": {
            f"family-{family_index:02d}": list(range(10))
            for family_index in range(12)
        },
        "rules": [], "selection_temperature": 1.0,
    })
    _write_jsonl(source / "inputs/main_design_candidate_instances.jsonl", instances)
    _write_jsonl(source / "raw/main_design_candidate_pool.jsonl", candidates)
    observation_path = source / "observations/main_design_noise_00_candidate.jsonl"
    _write_jsonl(observation_path, observations)
    _write_json(observation_path.with_suffix(observation_path.suffix + ".meta.json"), {
        "run_id": run_id, "rows": len(observations),
        "output_sha256": file_hash(observation_path),
    })
    return source, candidates


class PostmortemTests(unittest.TestCase):
    def test_selected_labels_follow_rule_ids_not_array_positions(self):
        rules_by_slot = {
            0: {"rule_id": "positive"},
            1: {"rule_id": "negative"},
        }
        observation = {
            "rule_ids": ["negative", "positive"],
            "labels": [-1, 1],
        }
        self.assertEqual(
            postmortem._labels_for_slots(observation, rules_by_slot, [0, 1]),
            [1, -1],
        )

    def test_failed_run_is_evaluated_outside_source_and_retry_is_read_only(self):
        run_id = "0123456789abcdef"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "artifacts"
            root.mkdir()
            source, candidates = _fixture(root, run_id)
            before = postmortem._tree_hashes(source)
            cache = Path(directory) / "cache"
            (cache / "ifbench").mkdir(parents=True)
            evaluator_file = cache / "ifbench/evaluation_lib.py"
            evaluator_file.write_text("# test\n", encoding="utf-8")
            calls = []

            def fake_check(items, *, workers):
                calls.append((len(items), workers))
                return [text.startswith("good") for _row, text in items]

            config = {
                "bootstrap_repetitions": 20, "confidence": .95,
                "dataset_seed": 7, "runtime": {"evaluator_workers": 2},
            }
            with (
                mock.patch.object(postmortem, "ARTIFACT_ROOT", root),
                mock.patch.object(postmortem, "CACHE", cache),
                mock.patch.object(postmortem, "_validate_evaluator", return_value={"evaluation_lib.py": "hash"}),
                mock.patch.object(postmortem, "load_evaluator", return_value=SimpleNamespace(__file__=str(evaluator_file))),
                mock.patch.object(postmortem, "official_check_many", side_effect=fake_check),
                mock.patch.object(postmortem, "load_config", return_value=config) as load_config,
            ):
                destination = postmortem.run_postmortem(run_id)
                self.assertEqual(load_config.call_count, 1)
                self.assertEqual(postmortem._tree_hashes(source), before)
                self.assertEqual(calls, [(len(candidates), 2)])
                self.assertEqual(
                    json.loads((destination / "DIAGNOSTIC_STATE.json").read_text())["state"],
                    "COMPLETE",
                )
                self.assertEqual(len(postmortem.read_jsonl(destination / "candidate_labels.jsonl")), 11_040)
                self.assertFalse((source / "labels/main_design_candidate_labels.jsonl").exists())
                summary = json.loads((destination / "summary.json").read_text())
                self.assertTrue(summary["posthoc_nonconfirmatory"])
                self.assertFalse(summary["test_rows_read"])
                self.assertEqual(postmortem.run_postmortem(run_id), destination)
                self.assertEqual(calls, [(len(candidates), 2)])
                self.assertEqual(load_config.call_count, 2)
                manifest_path = destination / "manifest.json"
                manifest = json.loads(manifest_path.read_text())
                manifest["protocol"] = "forged"
                _write_json(manifest_path, manifest)
                state_path = destination / "DIAGNOSTIC_STATE.json"
                state = json.loads(state_path.read_text())
                state["manifest_sha256"] = file_hash(manifest_path)
                _write_json(state_path, state)
                with self.assertRaisesRegex(RuntimeError, "identity drift"):
                    postmortem.run_postmortem(run_id)

    def test_rejects_test_row_before_official_evaluator(self):
        run_id = "0123456789abcdef"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "artifacts"
            root.mkdir()
            source, _ = _fixture(root, run_id)
            path = source / "inputs/main_design_candidate_instances.jsonl"
            rows = postmortem.read_jsonl(path)
            rows[0]["split"] = "test"
            _write_jsonl(path, rows)
            with (
                mock.patch.object(postmortem, "ARTIFACT_ROOT", root),
                mock.patch.object(postmortem, "_validate_evaluator", return_value={}),
                mock.patch.object(postmortem, "official_check_many") as official,
            ):
                with self.assertRaisesRegex(RuntimeError, "calibration/dev only"):
                    postmortem.run_postmortem(run_id)
            official.assert_not_called()

    def test_rejects_symlink_source_before_reading_it(self):
        run_id = "0123456789abcdef"
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "artifacts"
            target = base / "elsewhere"
            root.mkdir()
            target.mkdir()
            (root / run_id).symlink_to(target, target_is_directory=True)
            with mock.patch.object(postmortem, "ARTIFACT_ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "must not be a symlink"):
                    postmortem.validate_source(run_id)

    def test_root_cause_classifier_keeps_multiple_causes(self):
        family = "family"
        primary = {family: {
            "gold_valid": 300, "gold_invalid": 300,
            "valid_prompts": 30, "invalid_prompts": 30,
            "corrupt_rate": .01, "at_cap_rate": .5,
            "at_cap_candidates": 300, "complete_candidates": 300,
            "invalidity_lift_at_cap": .2,
            "invalidity_lift_at_cap_ci_low": .1,
        }}
        inventory = {family: {
            "technical_rules": 2, "positive_rules": 1, "negative_rules": 1,
            "conflict_rate": .02, "gold_aligned_rules": 1,
            "gold_aligned_authors": ["A"],
        }}
        temperatures = {family: {
            "delta_b_minus_a": .2, "ci_low": .1, "ci_high": .3,
        }}
        temperatures[family]["holm_p"] = .01
        result = postmortem._root_causes(
            primary, inventory, temperatures, {family},
        )[0]
        self.assertEqual(result["blocking_causes"], ["RULE_INVENTORY"])
        self.assertIn("RULE_INVENTORY", result["posthoc_signals"])
        self.assertIn("RULE_SEMANTICS_NOT_ESTABLISHED", result["posthoc_signals"])
        self.assertIn("TOKEN_BUDGET_VALIDITY_ASSOCIATION", result["posthoc_signals"])
        self.assertIn("TEMPERATURE", result["posthoc_signals"])


if __name__ == "__main__":
    unittest.main()
