from __future__ import annotations

import json
import copy
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path
from unittest import mock

import numpy as np

from pwseq_experiments.builders import MIXED_FAMILIES, SOFT_FAMILIES, build, build_mixed
from pwseq_experiments.common import DATA, EXPERIMENTS, atomic_jsonl_command, file_hash, read_jsonl, write_jsonl, write_jsonl_once
from pwseq_experiments.fuse import fit_fuse, predict_fuse
from pwseq_experiments.hard_validation import hard_accepts
from pwseq_experiments.metrics import (
    calibration_bins, classification_metrics, common_coverage_metrics,
    corrected_bootstrap_p, effective_rank, normalized_partial_aurc,
    operating_metrics, oracle_safe_solve, selective_curve,
)
from pwseq_experiments.data_validation import validate_dataset
from pwseq_experiments.pipeline import _operational_threshold
from pwseq_experiments.analysis import _accepts_threshold
from pwseq_experiments import common, pipeline, run as run_module
from pwseq_experiments import evaluator
from pwseq_experiments import archive as archive_module
from pwseq_experiments import analysis as analysis_module


class BuilderTests(unittest.TestCase):
    def test_frozen_builders_reproduce_prepared_data(self):
        for split in ["calibration", "dev", "test", "test_official"]:
            for row in read_jsonl(DATA / f"{split}.jsonl"):
                built = build(row["family"], row["kwargs"][0], row["max_tokens"])
                self.assertEqual(built.hard_spec, row["hard_spec"], row["id"])
                source_rules = [
                    {**rule, "source_slot": rule["slot"], "rule_id": built.weak_rules[i]["rule_id"]}
                    for i, rule in enumerate(row["weak_rules"])
                ]
                self.assertEqual(built.weak_rules, source_rules, row["id"])

    def test_builder_interface_has_no_hidden_inputs(self):
        import inspect
        self.assertEqual(list(inspect.signature(build).parameters), ["family", "kwargs", "max_tokens"])

    def test_mixed_builder_has_same_blind_interface(self):
        import inspect
        self.assertEqual(
            list(inspect.signature(build_mixed).parameters),
            ["family", "kwargs", "max_tokens"],
        )


class PreparedDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        validate_dataset()

    def test_counts_and_balance(self):
        expected = {
            "calibration": 360, "dev": 120, "hard_sanity": 60,
            "test": 600, "test_official": 67, "mixed": 720,
        }
        for split, count in expected.items():
            rows = read_jsonl(DATA / f"{split}.jsonl")
            self.assertEqual(len(rows), count)
            self.assertTrue(all("rack_llm_spec" not in row for row in rows))
            if split in {"calibration", "dev", "test"}:
                family_counts = Counter(row["family"] for row in rows)
                self.assertEqual(set(family_counts), set(SOFT_FAMILIES))
                self.assertEqual(len(set(family_counts.values())), 1)
                self.assertTrue(all(
                    all("rule_id" in rule and "source_slot" in rule
                        for rule in row["weak_rules"])
                    for row in rows
                ))

    def test_mixed_rows_are_paired_and_change_only_the_hard_envelope(self):
        pairs = defaultdict(list)
        for row in read_jsonl(DATA / "mixed.jsonl"):
            pairs[row["pair_id"]].append(row)
        self.assertTrue(pairs)
        for pair_id, arms in pairs.items():
            self.assertEqual({row["mixed_arm"] for row in arms}, {"text_weak", "coarse_hard_weak"})
            self.assertEqual(len(arms), 2, pair_id)
            weak, hard = sorted(arms, key=lambda row: row["mixed_arm"], reverse=True)
            self.assertEqual(weak["weak_rules"], hard["weak_rules"])
            self.assertNotEqual(weak["hard_spec"], hard["hard_spec"])

    def test_blind_authorship_and_model_separation_are_recorded(self):
        provenance = json.loads((DATA / "authoring_provenance.json").read_text())
        manifest = json.loads((DATA / "manifest.json").read_text())
        reviewer = json.loads((DATA / "reviewer.json").read_text())
        self.assertEqual(provenance["authoring_protocol"], "verifier-blind-v1")
        self.assertTrue(provenance["authors_isolated_from_coordinator_context"])
        self.assertTrue(provenance["coordinator_had_prior_failed_pilot_access"])
        self.assertFalse(provenance["semantic_rule_edits_by_coordinator"])
        self.assertFalse(provenance["gold_labels_used_for_authoring"])
        self.assertFalse(provenance["experimental_models_used_for_authoring"])
        self.assertEqual(provenance["experimental_model_role"], "candidate generation only")
        self.assertIn("two new family task splits", provenance["artifacts_authored"])
        packet_hashes = provenance["authoring_packets_sha256"]
        self.assertEqual(manifest["authoring_packets_sha256"], packet_hashes)
        self.assertEqual(
            packet_hashes,
            {
                name: file_hash(DATA / name)
                for name in ("author_a.json", "author_b.json", "reviewer.json")
            },
        )
        self.assertEqual(
            reviewer["approved_packet_sha256"],
            {name: packet_hashes[name] for name in ("author_a.json", "author_b.json")},
        )

    def test_validation_never_rewrites_dataset(self):
        before = {path.name: file_hash(path) for path in DATA.iterdir() if path.is_file()}
        validate_dataset()
        after = {path.name: file_hash(path) for path in DATA.iterdir() if path.is_file()}
        self.assertEqual(before, after)

    def test_test_prompts_and_parameters_are_disjoint(self):
        train = read_jsonl(DATA / "calibration.jsonl") + read_jsonl(DATA / "dev.jsonl")
        test = read_jsonl(DATA / "test.jsonl")
        self.assertEqual(len({row["base_prompt"] for row in test}), 600)
        self.assertFalse({row["prompt"] for row in train} & {row["prompt"] for row in test})
        train_values = defaultdict(set)
        test_values = defaultdict(set)
        for target, rows in [(train_values, train), (test_values, test)]:
            for row in rows:
                for key, value in row["kwargs"][0].items():
                    if value is not None:
                        target[(row["family"], key)].add(json.dumps(value, sort_keys=True))
        for key in train_values.keys() & test_values.keys():
            self.assertFalse(train_values[key] & test_values[key], key)

    def test_runtime_has_no_dataset_authoring_path(self):
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (EXPERIMENTS / "src" / "pwseq_experiments").glob("*.py")
        )
        for forbidden in [
            "build_test_generated", "test_per_family", "shutil.rmtree(DATA)",
            "write_jsonl(DATA", "prepare_data",
        ]:
            self.assertNotIn(forbidden, source)

    def test_frozen_noise_is_effective_and_nested(self):
        base = {}
        for split in ["calibration", "dev", "test", "test_official"]:
            base.update({row["id"]: row for row in read_jsonl(DATA / f"{split}.jsonl")})
        expected_types = {
            "polarity_flip", "narrow_literal", "over_broad_pattern",
            "word_boundary_removal", "case_sensitivity_error",
            "duplicate_conflicting_rule",
        }
        for level in [20, 40]:
            overlays = read_jsonl(DATA / f"noise_{level}.jsonl")
            self.assertEqual(len(overlays), len(base))
            seen = set()
            for overlay in overlays:
                row = base[overlay["instance_id"]]
                for change in overlay["changes"]:
                    clean = row["weak_rules"][change["slot"]]
                    if row["split"] in {"test", "test_official"}:
                        self.assertNotEqual(
                            (clean["polarity"], clean["pattern"]),
                            (change["polarity"], change["pattern"]),
                        )
                        seen.add(change["noise_type"])
            self.assertEqual(seen, expected_types)
        noise_20 = {
            row["instance_id"]: {(change["slot"], change["noise_type"]) for change in row["changes"]}
            for row in read_jsonl(DATA / "noise_20.jsonl")
        }
        noise_40 = {
            row["instance_id"]: {(change["slot"], change["noise_type"]) for change in row["changes"]}
            for row in read_jsonl(DATA / "noise_40.jsonl")
        }
        generated_ids = {
            row["id"] for row in base.values()
            if row["split"] in {"test", "test_official"}
        }
        for instance_id in generated_ids:
            self.assertLessEqual(noise_20[instance_id], noise_40[instance_id])

    def test_generation_modules_do_not_import_evaluator(self):
        forbidden = []
        for path in (EXPERIMENTS / "src" / "pwseq_experiments").glob("*.py"):
            if path.name in {
                "evaluator.py", "pipeline.py", "hard.py", "preflight.py", "freeze.py",
            }:
                continue
            text = path.read_text(encoding="utf-8")
            if "official_check" in text or "instructions_registry" in text:
                forbidden.append(path.name)
        self.assertEqual(forbidden, [])

    def test_experiment_client_uses_only_public_racket_api(self):
        forbidden = []
        for path in (EXPERIMENTS / "racket").glob("*.rkt"):
            text = path.read_text(encoding="utf-8")
            if "private/" in text or "tests/support" in text or "ffi/unsafe" in text:
                forbidden.append(path.name)
        self.assertEqual(forbidden, [])


class MetricTests(unittest.TestCase):
    def test_fuse_reimplementation_is_zero_label_and_predictive(self):
        rng = np.random.default_rng(17)
        latent = rng.integers(0, 2, size=4000)
        matrix = np.column_stack([
            np.where(rng.random(len(latent)) < .82, latent, 1 - latent),
            np.where(rng.random(len(latent)) < .75, latent, 1 - latent),
            np.where(rng.random(len(latent)) < .70, latent, 1 - latent),
            np.where(rng.random(len(latent)) < .65, latent, 1 - latent),
        ])
        signed = (2 * matrix - 1).tolist()
        model = fit_fuse(signed)
        self.assertEqual(model.status, "OK", model.reason)
        self.assertFalse(model.official_implementation)
        probability = predict_fuse(model, signed)
        self.assertGreater(np.corrcoef(probability, latent)[0, 1], .5)

    def test_classification_metrics(self):
        result = classification_metrics([0, 0, 1, 1], [.1, .2, .8, .9])
        self.assertAlmostEqual(result["auprc"], 1.0)
        self.assertAlmostEqual(result["auroc"], 1.0)
        self.assertLess(result["brier"], .05)

    def test_selective_metrics(self):
        rows = [
            {"outcome": "FOUND_OK", "confidence": .9},
            {"outcome": "FOUND_WRONG", "confidence": .8},
            {"outcome": "NOT_FOUND", "confidence": 0},
        ]
        curve = selective_curve(rows)
        self.assertGreaterEqual(normalized_partial_aurc(curve, 2 / 3), 0)
        self.assertAlmostEqual(oracle_safe_solve(curve, .05), 1 / 3)

    def test_common_coverage_prevents_abstention_advantage(self):
        full = selective_curve([
            {"outcome": "FOUND_OK", "confidence": .9},
            {"outcome": "FOUND_WRONG", "confidence": .8},
        ])
        short = selective_curve([
            {"outcome": "FOUND_OK", "confidence": .9},
            {"outcome": "NOT_FOUND", "confidence": 0},
        ])
        result = common_coverage_metrics({"full": full, "short": short})
        self.assertEqual(result["full"]["common_coverage"], .5)
        self.assertIsNone(result["short"]["risk_at_75"])

    def test_bootstrap_p_is_never_zero(self):
        self.assertGreater(corrected_bootstrap_p([1.0] * 10000), 0)

    def test_calibration_bins_are_shared_and_counted(self):
        groups = calibration_bins(np.asarray([0, 1, 1]), np.asarray([.1, .8, .9]), 2)
        self.assertEqual(sum(group["count"] for group in groups), 3)

    def test_selective_curve_groups_unorderable_confidence_ties(self):
        rows = [
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "FOUND_WRONG", "confidence": .8},
            {"outcome": "NOT_FOUND", "confidence": 0},
        ]
        curve = selective_curve(rows)
        self.assertEqual(len(curve), 2)
        self.assertAlmostEqual(curve[-1]["coverage"], 2 / 3)
        self.assertAlmostEqual(curve[-1]["risk"], .5)

    def test_operational_threshold_ignores_native_not_found(self):
        rows = [
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "FOUND_WRONG", "confidence": .7},
            {"outcome": "NOT_FOUND", "confidence": 1.0},
        ]
        self.assertEqual(_operational_threshold(rows, 0.05), .8)

    def test_operational_threshold_groups_ties(self):
        rows = [
            {"outcome": "FOUND_OK", "confidence": .9},
            {"outcome": "FOUND_OK", "confidence": .8},
            {"outcome": "FOUND_WRONG", "confidence": .8},
        ]
        self.assertEqual(_operational_threshold(rows, 0.05), .9)

    def test_serialized_reject_all_threshold_is_not_accept_all(self):
        row = {"confidence": 1.0}
        self.assertFalse(_accepts_threshold(row, {"accept_if": "never", "threshold": None}))
        self.assertTrue(_accepts_threshold(row, {"accept_if": "always", "threshold": None}))

    def test_effective_rank(self):
        matrix = np.eye(3)
        self.assertGreater(effective_rank(matrix), 1)


class RuntimePlumbingTests(unittest.TestCase):
    def test_failed_design_run_is_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "RUN_STATE.json"
            common.write_json(state, {"run_id": "test", "state": "FROZEN"})
            with (
                mock.patch.object(common, "STATE_FILE", state),
                mock.patch.object(run_module, "assert_frozen"),
                mock.patch.object(run_module, "preflight", return_value={"full_ok": True}),
                mock.patch.object(run_module, "run_design", side_effect=RuntimeError("gate failed")),
            ):
                with self.assertRaisesRegex(RuntimeError, "gate failed"):
                    run_module.run_stage("design")
                self.assertEqual(common.run_state(), "FAILED")

    def test_generation_bootstrap_uses_complete_prompt_seed_cohorts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifacts = root / "run"
            data = root / "data"
            (artifacts / "results").mkdir(parents=True)
            (artifacts / "thresholds").mkdir()
            data.mkdir()
            prompts = [
                {"id": "p0", "family": "family-a"},
                {"id": "p1", "family": "family-a"},
            ]
            write_jsonl(data / "test.jsonl", prompts)
            methods = [
                "hard_only_cars", "equal_score_best_of_b",
                "posterior_best_of_b", "exact_pwsg",
            ]
            raw = []
            for method in methods:
                for prompt in prompts:
                    for seed in [0, 1]:
                        raw.append({
                            "split": "test", "budget": 8,
                            "method": method, "prompt_id": prompt["id"],
                            "family": prompt["family"], "seed": seed,
                            "outcome": "FOUND_OK", "confidence": .8,
                        })
            write_jsonl(artifacts / "results" / "main_noise_00_generation_raw.jsonl", raw)
            write_jsonl(artifacts / "thresholds" / "main_noise_00.jsonl", [{
                "method": method, "budget": 8, "source_split": "dev",
                "threshold": .5, "accept_if": "confidence_gte",
            } for method in methods])
            config = {
                "confidence": .95, "generation_seeds": [0, 1],
                "bootstrap_repetitions": 5, "dataset_seed": 17,
            }
            with (
                mock.patch.object(analysis_module, "ARTIFACTS", artifacts),
                mock.patch.object(analysis_module, "load_config", return_value=config),
            ):
                result = analysis_module._bootstrap_generation()
            self.assertEqual(len(result), 3)
            self.assertTrue(any(row["comparison"].endswith("posterior_best_of_b") for row in result))

    def test_immutable_decision_artifact_rejects_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "thresholds.jsonl"
            write_jsonl_once(path, [{"threshold": .7}])
            write_jsonl_once(path, [{"threshold": .7}])
            with self.assertRaises(RuntimeError):
                write_jsonl_once(path, [{"threshold": .8}])

    def test_external_archive_is_immutable_and_hashed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "artifacts" / "run-1"
            run.mkdir(parents=True)
            (run / "frozen_manifest.json").write_text("{}\n")
            (run / "stage_status.json").write_text("{}\n")
            (run / "CLAIMS.json").write_text("[]\n")
            (run / "tables").mkdir()
            (run / "tables" / "statistical_tests.jsonl").write_text("{}\n")
            (run / "tables" / "table2b_temperature_ablation.csv").write_text("variant\n")
            (run / "tables" / "table3_generation.csv").write_text("method\n")
            (run / "tables" / "table5_mixed_hard_weak.csv").write_text("method\n")
            (run / "thresholds").mkdir()
            (run / "thresholds" / "main_noise_00.jsonl").write_text("{}\n")
            (run / "figures").mkdir()
            (run / "figures" / "risk_coverage.png").write_bytes(b"png")
            (run / "figures" / "risk_coverage_data.jsonl").write_text(
                '{"coverage":0,"risk":0,"risk_ci_low":0,"risk_ci_high":0,'
                '"bootstrap_repetitions":10,"bootstrap_support":10,'
                '"bootstrap_support_fraction":1}\n'
            )
            (run / "figures" / "quality_vs_budget.png").write_bytes(b"png")
            (run / "figures" / "quality_vs_budget_data.jsonl").write_text(
                '{"mean_model_tokens":1,"solve_rate":1,"solve_rate_ci_low":1,'
                '"solve_rate_ci_high":1,"solve_rate_support":10}\n'
            )
            (run / "figures" / "noise_robustness.png").write_bytes(b"png")
            (run / "figures" / "noise_robustness_data.jsonl").write_text(
                '{"noise":0,"solve_rate":1,"solve_rate_ci_low":1,'
                '"solve_rate_ci_high":1,"solve_rate_support":10,'
                '"found_wrong_rate":0,"found_wrong_rate_ci_low":0,'
                '"found_wrong_rate_ci_high":0,"found_wrong_rate_support":10,'
                '"not_found_rate":0,"not_found_rate_ci_low":0,'
                '"not_found_rate_ci_high":0,"not_found_rate_support":10}\n'
            )
            (run / "figures" / "found_wrong_vs_not_found.png").write_bytes(b"png")
            (run / "figures" / "reliability.png").write_bytes(b"png")
            (run / "figures" / "reliability_data.jsonl").write_text(
                '{"mean_probability":1,"empirical_rate":1,'
                '"empirical_rate_ci_low":1,"empirical_rate_ci_high":1,'
                '"bootstrap_repetitions":10,"bootstrap_support":10}\n'
            )
            destination = root / "release"
            with (
                mock.patch.object(archive_module, "ARTIFACTS", run),
                mock.patch.object(archive_module, "assert_frozen", return_value={}),
                mock.patch.object(archive_module, "frozen_manifest", return_value={"run_id": "run-1"}),
                mock.patch.object(archive_module, "run_state", return_value="READY_TO_ARCHIVE"),
                mock.patch.object(archive_module, "set_run_state"),
                mock.patch.dict(os.environ, {"PWSEQ_ARCHIVE_DIR": str(destination)}),
            ):
                target = archive_module.archive()
                self.assertTrue(target.is_file())
                self.assertTrue(target.with_suffix(target.suffix + ".sha256").is_file())
                with self.assertRaises(FileExistsError):
                    archive_module.archive()

    def test_engineering_baseline_keeps_invalid_returns_visible(self):
        source = (EXPERIMENTS / "src" / "pwseq_experiments" / "hard.py").read_text()
        self.assertNotIn('"not-found-hard-incomplete"', source)
        self.assertNotIn('row["text"] = ""', source)

    def test_fit_score_runner_is_model_free(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            instances = root / "instances.jsonl"
            observations = root / "observations.jsonl"
            output = root / "scores.jsonl"
            models = root / "models"
            write_jsonl(instances, [{"family": "test-family"}])
            rows = []
            for index in range(120):
                sign = 1 if index % 2 else -1
                rows.append({
                    "record_type": "observation",
                    "family": "test-family", "split": "calibration",
                    "prompt_id": f"p{index}", "seed": index,
                    "temperature": 1.0, "sample_index": 0,
                    "labels": [
                        0 if index % 7 == 0 else sign,
                        -sign if index % 11 == 0 else sign,
                        0 if index % 5 == 0 else sign,
                        -sign if index % 13 == 0 else sign,
                    ],
                    "rule_ids": [f"rule-{slot}" for slot in range(4)],
                })
            write_jsonl(observations, rows)
            env = dict(os.environ)
            env["PLTCOLLECTS"] = f"{EXPERIMENTS.parent.parent}:"
            command = [
                "racket", str(EXPERIMENTS / "racket" / "rack_runner.rkt"),
                "--mode", "fit-score", "--input", str(instances),
                "--candidates", str(observations), "--output", str(output),
                "--models-dir", str(models),
                "--runtime-fingerprint", "model-free-test",
            ]
            self.assertNotIn("--model", command)
            subprocess.run(command, cwd=EXPERIMENTS.parent, env=env, check=True)
            records = read_jsonl(output)
            self.assertEqual(records[0]["record_type"], "fit")
            self.assertTrue((models / "test-family.json").exists())

    def test_native_regex_validator_abi(self):
        self.assertTrue(hard_accepts({"kind": "ere", "pattern": "^a$"}, "a"))
        self.assertFalse(hard_accepts({"kind": "ere", "pattern": "^a$"}, "b"))
        with self.assertRaises(RuntimeError):
            hard_accepts({"kind": "ere", "pattern": "("}, "a")

    def test_text_hard_rule_accepts_empty_zero_token_result(self):
        self.assertTrue(hard_accepts({"kind": "text", "max_tokens": 4}, "", 0))
        self.assertFalse(hard_accepts({"kind": "text", "max_tokens": 4}, "x", 5))

    def test_official_evaluator_deduplicates_and_persists_results(self):
        row = {
            "prompt": "p", "instruction_id_list": ["x"],
            "kwargs": [{"value": 1}],
        }
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(evaluator, "CACHE", Path(directory)),
                mock.patch.object(evaluator, "_EVALUATOR_FINGERPRINT", "test-evaluator"),
                mock.patch.object(evaluator, "load_evaluator", return_value=object()),
                mock.patch.object(
                    evaluator, "official_check", side_effect=lambda _row, text, _registry: text == "ok"
                ) as check,
            ):
                self.assertEqual(
                    evaluator.official_check_many(
                        [(row, "ok"), (row, "ok"), (row, "bad")], workers=1
                    ),
                    [True, True, False],
                )
                self.assertEqual(check.call_count, 2)
                self.assertEqual(
                    evaluator.official_check_many([(row, "ok")], workers=1), [True]
                )
                self.assertEqual(check.call_count, 2)

    def test_official_evaluator_wrapper_matches_pinned_strict_api(self):
        module = evaluator.load_evaluator()
        row = read_jsonl(DATA / "test_official.jsonl")[0]
        original_kwargs = copy.deepcopy(row["kwargs"])
        text = "deliberately short response"
        example = module.InputExample(
            key=row.get("source_key", 0),
            instruction_id_list=list(row["instruction_id_list"]),
            prompt=row["prompt"],
            kwargs=copy.deepcopy(row["kwargs"]),
        )
        direct = module.test_instruction_following_strict(
            example, {row["prompt"]: text}
        ).follow_all_instructions
        self.assertEqual(evaluator.official_check(row, text, module), direct)
        self.assertEqual(row["kwargs"], original_kwargs)

    def test_runner_receives_frozen_cpu_and_gpu_resources(self):
        config = {
            "runtime": {
                "context_size": 2048, "model_threads": 3,
                "regex_threads": 7, "gpu_devices": [2, 5],
            }
        }
        with (
            mock.patch.object(pipeline, "load_config", return_value=config),
            mock.patch.object(
                pipeline, "frozen_manifest",
                return_value={"files": {}, "external_files": {},
                              "llama_cpp_revision": "llama", "ifbench_revision": "ifbench"},
            ),
            mock.patch.object(pipeline, "atomic_jsonl_command", return_value=Path("out")) as run,
        ):
            pipeline._run_racket(
                "generate.worker1", ["--input", "in", "--output", "out"],
                Path("out"), 1,
            )
        command = run.call_args.args[1]
        environment = run.call_args.kwargs["env"]
        self.assertEqual(command[command.index("--context-size") + 1], "2048")
        self.assertEqual(command[command.index("--model-threads") + 1], "3")
        self.assertIn("--runtime-fingerprint", command)
        self.assertEqual(environment["OMP_NUM_THREADS"], "7")
        self.assertEqual(environment["OMP_DYNAMIC"], "FALSE")
        self.assertEqual(environment["CUDA_VISIBLE_DEVICES"], "5")

    def test_prompt_shards_merge_in_canonical_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input.jsonl"
            output = root / "output.jsonl"
            write_jsonl(source, [{"id": f"p{index}"} for index in range(4)])

            def fake_runner(stage, args, target, expected_rows=None):
                shard = Path(args[args.index("--input") + 1])
                rows = []
                for item in read_jsonl(shard):
                    for seed in [0, 1]:
                        rows.append({
                            "prompt_id": item["id"], "seed": seed,
                            "sample_index": 0, "record_type": "sample",
                        })
                self.assertEqual(len(rows), expected_rows)
                write_jsonl(target, rows)
                return target

            args = ["--input", str(source), "--output", str(output)]
            with (
                mock.patch.object(pipeline, "ARTIFACTS", root / "artifacts"),
                mock.patch.object(
                    pipeline, "load_config",
                    return_value={"runtime": {"generation_workers": 2}},
                ),
                mock.patch.object(pipeline, "_run_racket", side_effect=fake_runner),
            ):
                pipeline._run_racket_sharded(
                    "test.shards", args, output, records_per_input=2
                )
            self.assertEqual(
                [(row["prompt_id"], row["seed"]) for row in read_jsonl(output)],
                [(f"p{prompt}", seed) for prompt in range(4) for seed in [0, 1]],
            )

    def test_atomic_command_rejects_empty_and_reuses_valid_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "rows.jsonl"
            command = [
                sys.executable, "-c",
                "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\\\"x\\\":1}\\n')",
                str(output),
            ]
            with mock.patch.object(common, "ARTIFACTS", root / "artifacts"):
                atomic_jsonl_command("atomic.test", command, output, expected_rows=1)
                first_mtime = output.stat().st_mtime_ns
                atomic_jsonl_command("atomic.test", command, output, expected_rows=1)
                self.assertEqual(output.stat().st_mtime_ns, first_mtime)

                bad = root / "bad.jsonl"
                bad_command = [
                    sys.executable, "-c",
                    "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('')",
                    str(bad),
                ]
                with self.assertRaises(RuntimeError):
                    atomic_jsonl_command("atomic.bad", bad_command, bad, expected_rows=1)
                self.assertFalse(bad.exists())


if __name__ == "__main__":
    unittest.main()
