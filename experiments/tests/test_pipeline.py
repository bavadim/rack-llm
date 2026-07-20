from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from pwseq_experiments import common, evaluator, hard, pipeline, run
from pwseq_experiments.common import (
    atomic_jsonl_command,
    file_hash,
    read_jsonl,
    write_json,
    write_jsonl,
)


def _cache_fixture(root: Path):
    experiments = root / "experiments"
    data = root / "data"
    source_root = experiments / "artifacts" / "source-run"
    (source_root / "raw").mkdir(parents=True)
    (source_root / "inputs").mkdir()
    data.mkdir()
    gguf = root / "model.gguf"
    gguf.write_bytes(b"exact frozen model")
    dataset = data / "calibration.jsonl"
    dataset.write_text('{"id":"p"}\n', encoding="utf-8")
    rendered = {
        "id": "p", "family": "family", "split": "calibration",
        "model_family": "qwen3.5", "model_prompt": "CHAT:p",
        "hard_spec": {"kind": "text", "max_tokens": 4}, "max_tokens": 4,
    }
    instances = source_root / "inputs" / "instances.jsonl"
    write_jsonl(instances, [rendered])
    candidate = {
        "artifact_schema_version": 2,
        "prompt_id": "p", "family": "family", "split": "calibration",
        "model_family": "qwen3.5", "temperature": 1.0,
        "seed": 0, "sample_index": 0, "text": "answer", "token_ids": [1],
        "status": "found", "hard_valid": True,
        "tokenizer_fingerprint": "tokenizer:one",
        "runtime_fingerprint": "runtime:one",
    }
    candidate["candidate_id"] = pipeline._candidate_id(candidate, "qwen3.5")
    pool = source_root / "raw" / "pool.jsonl"
    write_jsonl(pool, [candidate])
    manifest = {
        "run_id": "source-run", "artifact_schema_version": 3,
        "protocol_version": "paper-v5", "git_revision": "source-git",
        "llama_cpp_revision": "llama-revision",
        "external_files": {str(gguf): file_hash(gguf)},
    }
    manifest_path = source_root / "frozen_manifest.json"
    write_json(manifest_path, manifest)
    config = {
        "native": {"llama_cpp_commit": "llama-revision"},
        "runtime": {"cohort_width": 32, "gpu_devices": [0]},
        "candidate_cache_import": {
            "model_family": "qwen3.5", "eligible_model_names": ["main"],
            "source_run_id": "source-run", "source_relative_path": "raw/pool.jsonl",
            "sha256": file_hash(pool),
            "source_frozen_manifest_sha256": file_hash(manifest_path),
            "source_manifest_schema_version": 3,
            "source_protocol_revision": "paper-v5",
            "source_git_revision": "source-git",
            "source_llama_cpp_revision": "llama-revision",
            "source_gguf_path": str(gguf), "source_gguf_sha256": file_hash(gguf),
            "source_instances_relative_path": "inputs/instances.jsonl",
            "source_instances_sha256": file_hash(instances),
            "source_candidate_schema_version": 2,
            "tokenizer_fingerprint": "tokenizer:one",
            "source_runtime": {"cohort_width": 32, "gpu_devices": [0]},
            "allowed_splits": ["calibration", "dev"],
            "dataset_files": {"calibration.jsonl": file_hash(dataset)},
        },
    }
    model = {"family": "qwen3.5", "gguf_path": str(gguf)}
    expected = {pipeline._candidate_key(candidate)}
    return experiments, data, config, model, rendered, expected


class PipelineTests(unittest.TestCase):
    def test_calibration_precedes_gold_and_test_stages_require_frozen_design(self):
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
            run.run_aggregation("main", 0.0)
        self.assertEqual(events, ["fit", "official"])
        with (
            mock.patch.object(run, "assert_frozen"),
            mock.patch.object(run, "preflight", return_value={"full_ok": True}),
            mock.patch.object(run, "load_config", return_value={}),
            mock.patch.object(run, "run_aggregation") as aggregation,
        ):
            with self.assertRaisesRegex(RuntimeError, "finalized dev-only design"):
                run.run_stage("aggregation")
        aggregation.assert_not_called()

    def test_calibration_errors_remain_explicit(self):
        rows = pipeline._score_rows_with_explicit_calibration_status([{
            "record_type": "score_error", "candidate_id": "candidate",
            "family": "family", "labels": [1, 0, -1], "message": "failed",
        }])
        self.assertEqual(rows[0]["record_type"], "score")
        self.assertEqual(rows[0]["calibration_status"], "ERROR")
        self.assertIsNone(rows[0]["posterior"])
        self.assertEqual(rows[0]["labels"], [1, 0, -1])

    def test_candidate_cache_is_normalized_and_rejects_lineage_mismatch(self):
        def imported(fixture, *, model=None, rendered=None):
            experiments, data, config, base_model, base_rendered, expected = fixture
            with (
                mock.patch.object(pipeline, "EXPERIMENTS", experiments),
                mock.patch.object(pipeline, "DATA", data),
                mock.patch.object(pipeline, "load_config", return_value=config),
            ):
                return pipeline._import_candidate_cache(
                    model or base_model, [rendered or base_rendered], expected, "main",
                )

        with tempfile.TemporaryDirectory() as directory:
            fixture = _cache_fixture(Path(directory))
            rows, lineage = imported(fixture)
            self.assertEqual(rows[0]["artifact_schema_version"], 4)
            self.assertIs(rows[0]["terminal_mass"], False)
            self.assertEqual(lineage["source_candidate_artifact_schema_versions"], [2])
            changed = {**fixture[4], "model_prompt": "DIFFERENT CHAT TEMPLATE"}
            with self.assertRaisesRegex(RuntimeError, "prompt mismatch"):
                imported(fixture, rendered=changed)
        with tempfile.TemporaryDirectory() as directory:
            fixture = _cache_fixture(Path(directory))
            other = Path(directory) / "other.gguf"
            other.write_bytes(b"different model")
            with self.assertRaisesRegex(RuntimeError, "model mismatch"):
                imported(fixture, model={"family": "qwen3.5", "gguf_path": str(other)})

    def test_ifbench_adapter_copies_inputs_and_caches_duplicate_verdicts(self):
        captured = []

        class Adapter:
            @staticmethod
            def InputExample(**kwargs):
                captured.append(kwargs)
                return SimpleNamespace(**kwargs)

            @staticmethod
            def test_instruction_following_strict(example, responses):
                return SimpleNamespace(
                    follow_all_instructions=responses[example.prompt] == "ok",
                )

        row = {
            "source_key": 3, "prompt": "p", "instruction_id_list": ["x"],
            "kwargs": [{"value": [1]}],
        }
        original = copy.deepcopy(row)
        self.assertTrue(evaluator.official_check(row, "ok", Adapter))
        captured[0]["kwargs"][0]["value"].append(2)
        self.assertEqual(row, original)
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(evaluator, "CACHE", Path(directory)),
                mock.patch.object(evaluator, "_EVALUATOR_FINGERPRINT", "test-evaluator"),
                mock.patch.object(evaluator, "load_evaluator", return_value=object()),
                mock.patch.object(
                    evaluator, "official_check",
                    side_effect=lambda _row, text, _registry: text == "ok",
                ) as check,
            ):
                self.assertEqual(
                    evaluator.official_check_many(
                        [(row, "ok"), (row, "ok"), (row, "bad")], workers=1,
                    ),
                    [True, True, False],
                )
                self.assertEqual(check.call_count, 2)

    def test_runner_receives_frozen_cpu_and_gpu_resources(self):
        config = {"runtime": {
            "context_size": 2048, "model_threads": 3,
            "regex_threads": 7, "gpu_devices": [2, 5],
        }}
        with (
            mock.patch.object(pipeline, "load_config", return_value=config),
            mock.patch.object(
                pipeline, "frozen_manifest",
                return_value={"files": {}, "external_files": {},
                              "llama_cpp_revision": "llama", "ifbench_revision": "ifbench"},
            ),
            mock.patch.object(
                pipeline, "atomic_jsonl_command", return_value=Path("out"),
            ) as execute,
        ):
            pipeline._run_racket(
                "generate.worker1", ["--input", "in", "--output", "out"],
                Path("out"), 1,
            )
        command = execute.call_args.args[1]
        environment = execute.call_args.kwargs["env"]
        self.assertEqual(command[command.index("--context-size") + 1], "2048")
        self.assertEqual(command[command.index("--model-threads") + 1], "3")
        self.assertIn("--runtime-fingerprint", command)
        self.assertEqual(environment["OMP_NUM_THREADS"], "7")
        self.assertEqual(environment["OMP_DYNAMIC"], "FALSE")
        self.assertEqual(environment["CUDA_VISIBLE_DEVICES"], "5")

    def test_prompt_shards_merge_in_canonical_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "input.jsonl", root / "output.jsonl"
            write_jsonl(source, [{"id": f"p{index}"} for index in range(4)])

            def fake_runner(_stage, args, target, expected_rows=None):
                shard = Path(args[args.index("--input") + 1])
                rows = [{
                    "prompt_id": item["id"], "seed": seed,
                    "sample_index": 0, "record_type": "sample",
                } for item in read_jsonl(shard) for seed in (0, 1)]
                self.assertEqual(len(rows), expected_rows)
                write_jsonl(target, rows)
                write_json(target.with_suffix(target.suffix + ".meta.json"), {
                    "wall_seconds": 1.25,
                })
                return target

            with (
                mock.patch.object(pipeline, "ARTIFACTS", root / "artifacts"),
                mock.patch.object(
                    pipeline, "load_config",
                    return_value={"runtime": {"generation_workers": 2}},
                ),
                mock.patch.object(pipeline, "_run_racket", side_effect=fake_runner),
            ):
                pipeline._run_racket_sharded(
                    "test.shards", ["--input", str(source), "--output", str(output)],
                    output, records_per_input=2,
                )
            self.assertEqual(
                [(row["prompt_id"], row["seed"]) for row in read_jsonl(output)],
                [(f"p{prompt}", seed) for prompt in range(4) for seed in (0, 1)],
            )
            metadata = json.loads(
                output.with_suffix(output.suffix + ".meta.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(metadata["workers"], 2)
            self.assertEqual(metadata["worker_seconds"], 2.5)
            self.assertGreaterEqual(metadata["wall_seconds"], 0.0)
            self.assertGreaterEqual(metadata["rows_per_second"], 0.0)

    def test_atomic_outputs_are_reused_or_removed_on_failure(self):
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
                metadata = json.loads(
                    output.with_suffix(output.suffix + ".meta.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertGreaterEqual(metadata["wall_seconds"], 0.0)
                self.assertGreaterEqual(metadata["rows_per_second"], 0.0)
                first_mtime = output.stat().st_mtime_ns
                atomic_jsonl_command("atomic.test", command, output, expected_rows=1)
                self.assertEqual(output.stat().st_mtime_ns, first_mtime)
                bad = root / "bad.jsonl"
                with self.assertRaises(RuntimeError):
                    atomic_jsonl_command(
                        "atomic.bad",
                        [sys.executable, "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('')", str(bad)],
                        bad, expected_rows=1,
                    )
                self.assertFalse(bad.exists())

    def test_hard_summary_separates_backend_failures_from_refusals(self):
        rows = [
            {
                "outcome": "FOUND_OK", "hard_valid": True,
                "latency_ms": 10.0, "token_count": 3,
            },
            {
                "outcome": "FOUND_WRONG", "hard_valid": False,
                "latency_ms": 20.0, "token_count": 4,
            },
            {
                "outcome": "NOT_FOUND", "hard_valid": False,
                "latency_ms": 30.0, "token_count": 0,
            },
            {
                "outcome": "BACKEND_ERROR", "hard_valid": False,
                "latency_ms": None, "token_count": 0,
            },
        ]
        summary = hard._summarize_method(
            "guidance", rows, expected_runs=4, wall_seconds=2.0,
        )
        self.assertEqual(summary["found_ok"], 1)
        self.assertEqual(summary["found_wrong"], 1)
        self.assertEqual(summary["not_found"], 1)
        self.assertEqual(summary["backend_errors"], 1)
        self.assertEqual(summary["inference_status"], "BLOCKED")
        self.assertEqual(summary["benchmark_status"], "PARTIALLY_BLOCKED")
        self.assertIsNone(summary["solve_rate"])
        self.assertEqual(
            summary["descriptive_solve_rate_including_backend_errors"], .25,
        )
        self.assertEqual(summary["unconditional_hard_valid_rate"], .25)
        self.assertEqual(summary["conditional_hard_valid_rate"], .5)
        self.assertEqual(summary["invalid_return_rate"], .5)
        self.assertEqual(summary["median_latency_ms"], 20.0)
        self.assertEqual(summary["runs_per_second"], 1.5)
        self.assertEqual(summary["grid_rows_per_second"], 2.0)

        failed = hard._summarize_method(
            "outlines",
            [{"outcome": "BACKEND_ERROR", "hard_valid": False,
              "latency_ms": None}],
            expected_runs=1, wall_seconds=.5,
        )
        self.assertEqual(failed["benchmark_status"], "BASELINE_FAILED")
        self.assertEqual(failed["inference_status"], "BLOCKED")
        self.assertIsNone(failed["solve_rate"])

    def test_hard_baseline_initialization_failure_emits_blocked_grid(self):
        source = [{"id": "p", "family": "f", "split": "hard_sanity"}]
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(hard, "ARTIFACTS", Path(directory)),
            mock.patch.object(
                hard, "load_config", return_value={"generation_seeds": [0, 1]},
            ),
            mock.patch.object(
                hard, "_load_hf_backend",
                side_effect=RuntimeError("backend unavailable"),
            ),
            mock.patch.object(hard, "issue") as record_issue,
        ):
            output = hard._hf_baseline("guidance", source, "main")
            rows = read_jsonl(output)
            metadata = json.loads(
                output.with_suffix(output.suffix + ".meta.json").read_text(
                    encoding="utf-8"
                )
            )
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["status"] for row in rows}, {"backend-error"})
        self.assertEqual(metadata["benchmark_status"], "BASELINE_FAILED")
        self.assertEqual(metadata["inference_status"], "BLOCKED")
        self.assertEqual(metadata["backend_errors"], 2)
        record_issue.assert_called_once()


if __name__ == "__main__":
    unittest.main()
