from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pwseq_experiments import pipeline
from pwseq_experiments.common import file_hash, write_json, write_jsonl


def _fixture(root: Path):
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
    source_instances = source_root / "inputs" / "instances.jsonl"
    write_jsonl(source_instances, [rendered])
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
            "source_run_id": "source-run",
            "source_relative_path": "raw/pool.jsonl",
            "sha256": file_hash(pool),
            "source_frozen_manifest_sha256": file_hash(manifest_path),
            "source_manifest_schema_version": 3,
            "source_protocol_revision": "paper-v5",
            "source_git_revision": "source-git",
            "source_llama_cpp_revision": "llama-revision",
            "source_gguf_path": str(gguf),
            "source_gguf_sha256": file_hash(gguf),
            "source_instances_relative_path": "inputs/instances.jsonl",
            "source_instances_sha256": file_hash(source_instances),
            "source_candidate_schema_version": 2,
            "tokenizer_fingerprint": "tokenizer:one",
            "source_runtime": {"cohort_width": 32, "gpu_devices": [0]},
            "allowed_splits": ["calibration", "dev"],
            "dataset_files": {"calibration.jsonl": file_hash(dataset)},
        },
    }
    model = {"family": "qwen3.5", "gguf_path": str(gguf)}
    expected = {pipeline._candidate_key(candidate)}
    return experiments, data, config, model, rendered, expected, manifest_path


class CandidateCacheLineageTests(unittest.TestCase):
    def _import(self, fixture, *, model=None, rendered=None):
        experiments, data, config, base_model, base_rendered, expected, _ = fixture
        with (
            mock.patch.object(pipeline, "EXPERIMENTS", experiments),
            mock.patch.object(pipeline, "DATA", data),
            mock.patch.object(pipeline, "load_config", return_value=config),
        ):
            return pipeline._import_candidate_cache(
                model or base_model, [rendered or base_rendered], expected, "main"
            )

    def test_import_is_normalized_and_records_source_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            rows, lineage = self._import(_fixture(Path(directory)))
        self.assertEqual(rows[0]["artifact_schema_version"], 4)
        self.assertIs(rows[0]["terminal_mass"], False)
        self.assertIs(rows[0]["calibration_fingerprint"], False)
        self.assertEqual(lineage["source_candidate_artifact_schema_versions"], [2])
        self.assertEqual(lineage["normalized_artifact_schema_version"], 4)
        self.assertEqual(lineage["tokenizer_fingerprint"], "tokenizer:one")

    def test_rejects_current_model_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = _fixture(Path(directory))
            other = Path(directory) / "other.gguf"
            other.write_bytes(b"different model")
            with self.assertRaisesRegex(RuntimeError, "model mismatch"):
                self._import(fixture, model={
                    "family": "qwen3.5", "gguf_path": str(other),
                })

    def test_rejects_rendered_prompt_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = _fixture(Path(directory))
            changed = {**fixture[4], "model_prompt": "DIFFERENT CHAT TEMPLATE"}
            with self.assertRaisesRegex(RuntimeError, "prompt mismatch"):
                self._import(fixture, rendered=changed)

    def test_rejects_execution_profile_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = _fixture(Path(directory))
            fixture[2]["runtime"]["cohort_width"] = 16
            with self.assertRaisesRegex(RuntimeError, "execution profile"):
                self._import(fixture)

    def test_rejects_tampered_source_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = _fixture(Path(directory))
            fixture[-1].write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "frozen manifest hash mismatch"):
                self._import(fixture)


if __name__ == "__main__":
    unittest.main()
