from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pwseq_experiments import analysis, pipeline
from pwseq_experiments.common import EXPERIMENTS, read_jsonl, write_jsonl


class TemperaturePolicyTests(unittest.TestCase):
    def test_frozen_policy_separates_primary_fit_and_audit_mixture(self):
        policy = pipeline.temperature_policy()
        self.assertEqual(policy["primary_temperature"], 1.0)
        self.assertEqual(policy["rule_audit_temperatures"], [0.7, 1.0])
        self.assertEqual(policy["primary_calibration_seeds"], list(range(20)))
        self.assertEqual(policy["audit_calibration_seeds"], list(range(8)))
        self.assertEqual(policy["candidate_evaluation_seeds"], list(range(8)))
        self.assertEqual(
            policy["weak_model_variants"]["primary"],
            {"fit_temperatures": [1.0], "aggregation_only": False},
        )
        self.assertEqual(
            policy["weak_model_variants"]["mixture_0p7_1p0"],
            {"fit_temperatures": [0.7, 1.0], "aggregation_only": True},
        )

    def test_primary_runtime_paths_are_configured(self):
        sources = [
            (EXPERIMENTS / "src" / "pwseq_experiments" / name).read_text()
            for name in ["pipeline.py", "hard.py"]
        ]
        source = "\n".join(sources)
        self.assertNotIn('config["calibration_temperatures"]', source)
        self.assertNotIn('"--temperature", "1.0"', source)

    def test_paper_v5_seed_cardinalities_are_not_tunable(self):
        config = pipeline.load_config()
        changed = {**config, "primary_calibration_seeds": list(range(19))}
        with self.assertRaisesRegex(ValueError, "paper-v5 fixes"):
            pipeline.temperature_policy(changed)

    def test_racket_fit_temperature_selection_is_model_free_and_variant_tagged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            instances = root / "instances.jsonl"
            observations = root / "observations.jsonl"
            write_jsonl(instances, [{"family": "temperature-family"}])
            rows = []
            for temperature in (0.7, 1.0):
                for index in range(120):
                    sign = 1 if index % 2 else -1
                    if temperature == 0.7:
                        sign = -sign
                    rows.append({
                        "record_type": "observation",
                        "family": "temperature-family",
                        "split": "calibration",
                        "prompt_id": f"p-{temperature}-{index}",
                        "candidate_id": f"c-{temperature}-{index}",
                        "seed": index,
                        "temperature": temperature,
                        "sample_index": 0,
                        "labels": [
                            sign,
                            -sign if index % 5 == 0 else sign,
                            0 if index % 7 == 0 else sign,
                            -sign if index % 11 == 0 else sign,
                        ],
                        "rule_ids": [f"rule-{slot}" for slot in range(4)],
                    })
            write_jsonl(observations, rows)

            def run(name: str, temperatures: str, source: Path = observations):
                output = root / f"{name}.jsonl"
                models = root / f"models-{name}"
                env = dict(os.environ)
                env["PLTCOLLECTS"] = f"{EXPERIMENTS.parent.parent}:"
                subprocess.run([
                    "racket", str(EXPERIMENTS / "racket" / "rack_runner.rkt"),
                    "--mode", "fit-score",
                    "--input", str(instances),
                    "--candidates", str(source),
                    "--output", str(output),
                    "--models-dir", str(models),
                    "--fit-temperatures", temperatures,
                    "--fit-variant", name,
                    "--runtime-fingerprint", "temperature-policy-test",
                ], cwd=EXPERIMENTS.parent, env=env, check=True)
                records = read_jsonl(output)
                return records[0], records

            primary, primary_rows = run("primary", "1.0")
            mixture, mixture_rows = run("mixture_0p7_1p0", "0.7,1.0")
            self.assertEqual(primary["fit_training_rows"], 120)
            self.assertEqual(primary["fit_temperatures"], [1.0])
            self.assertEqual(mixture["fit_training_rows"], 240)
            self.assertEqual(mixture["fit_temperatures"], [0.7, 1.0])
            self.assertTrue(all(
                row["variant"] == "primary"
                for row in primary_rows if row["record_type"] == "score"
            ))
            self.assertTrue(all(
                row["variant"] == "mixture_0p7_1p0"
                for row in mixture_rows if row["record_type"] == "score"
            ))

            changed = [dict(row) for row in rows]
            for row in changed:
                if row["temperature"] == 0.7:
                    row["labels"] = [0, 0, 0, 0]
            changed_path = root / "observations-changed.jsonl"
            write_jsonl(changed_path, changed)
            primary_changed, _ = run("primary_changed", "1.0", changed_path)
            self.assertEqual(
                primary["weak_model_fingerprint"],
                primary_changed["weak_model_fingerprint"],
            )

    def test_temperature_ablation_rejects_different_candidate_pools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            labels = root / "labels.jsonl"
            primary = root / "primary.jsonl"
            mixture = root / "mixture.jsonl"
            write_jsonl(labels, [
                {"candidate_id": "candidate-1", "gold_pass": True},
                {"candidate_id": "candidate-2", "gold_pass": False},
            ])
            base = {
                "record_type": "score", "split": "test", "family": "family",
                "temperature": 1.0, "labels": [1, 0, -1], "posterior": 0.8,
            }
            write_jsonl(primary, [{**base, "variant": "primary", "candidate_id": "candidate-1"}])
            write_jsonl(mixture, [{
                **base, "variant": "mixture_0p7_1p0", "candidate_id": "candidate-2",
            }])
            with mock.patch.object(pipeline, "ARTIFACTS", root / "artifacts"):
                with self.assertRaisesRegex(RuntimeError, "candidate pools differ"):
                    pipeline.temperature_ablation_report(
                        "main", 0.0, primary, mixture, labels
                    )

    def test_temperature_ablation_scores_identical_primary_temperature_pool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            labels_path = root / "labels.jsonl"
            primary_path = root / "primary.jsonl"
            mixture_path = root / "mixture.jsonl"
            labels = []
            primary = []
            mixture = []
            for split in ("dev", "test", "test_official"):
                for index, gold in enumerate((False, True)):
                    candidate_id = f"{split}-{index}"
                    labels.append({"candidate_id": candidate_id, "gold_pass": gold})
                    base = {
                        "record_type": "score", "candidate_id": candidate_id,
                        "split": split, "family": "family", "temperature": 1.0,
                        "labels": [1, 0, -1],
                    }
                    primary.append({
                        **base, "variant": "primary",
                        "posterior": 0.8 if gold else 0.2,
                    })
                    mixture.append({
                        **base, "variant": "mixture_0p7_1p0",
                        "posterior": 0.7 if gold else 0.3,
                    })
            write_jsonl(labels_path, labels)
            write_jsonl(primary_path, primary)
            write_jsonl(mixture_path, mixture)
            artifacts = root / "artifacts"
            with mock.patch.object(pipeline, "ARTIFACTS", artifacts):
                output = pipeline.temperature_ablation_report(
                    "main", 0.0, primary_path, mixture_path, labels_path
                )
            rows = read_jsonl(output)
            self.assertEqual(len(rows), 6)
            self.assertEqual({row["variant"] for row in rows}, {
                "primary", "mixture_0p7_1p0",
            })
            self.assertEqual({row["split"] for row in rows}, {
                "dev", "test", "test_official",
            })
            self.assertTrue(all(row["evaluation_temperature"] == 1.0 for row in rows))
            table = analysis._temperature_ablation_table(output)
            self.assertEqual(len(table), 6)
            self.assertEqual({row["families"] for row in table}, {1})
            self.assertEqual(
                {row["fit_temperatures"] for row in table},
                {"1.0", "0.7,1.0"},
            )


if __name__ == "__main__":
    unittest.main()
