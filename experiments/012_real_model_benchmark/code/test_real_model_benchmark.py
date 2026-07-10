#!/usr/bin/env python3
"""Fail-closed checks for the Experiment 012 real benchmark package."""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_real_model_benchmark import EXPERIMENT_DIR, REQUIRED_DATA, preflight
from setup_real_backend import CheckResult, missing_markdown
from strict_json import strict_json_dumps, write_jsonl


REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = EXPERIMENT_DIR / "code" / "run_real_model_benchmark.py"
ROOT_BACKEND_METADATA = REPO_ROOT / "data" / "012_backend_metadata.json"
CONFIG_LOCK = EXPERIMENT_DIR / "config.lock.json"
ARTIFACT_MANIFEST = EXPERIMENT_DIR / "ARTIFACT_MANIFEST.json"
REPRODUCE = EXPERIMENT_DIR / "REPRODUCE.md"

FINAL_ARTIFACTS = [
    REPO_ROOT / "data" / "005_hard_solve_raw.jsonl",
    REPO_ROOT / "data" / "010_soft_noisy_raw.jsonl",
    REPO_ROOT / "data" / "012_soft_candidate_pool.jsonl",
    EXPERIMENT_DIR / "results" / "012_ours_soft_generation_raw.jsonl",
    REPO_ROOT / "data" / "012_soft_real_raw.jsonl",
]

ACTIVE_CODE_DIRS = [
    REPO_ROOT / "experiments" / "005_hard_solve" / "code",
    REPO_ROOT / "experiments" / "008_soft_rule_audit" / "code",
    REPO_ROOT / "experiments" / "009_soft_methods" / "code",
    REPO_ROOT / "experiments" / "010_soft_noisy_benchmark" / "code",
    EXPERIMENT_DIR / "code",
]

OLD_BACKEND_MARKERS = [
    "hf_logits_sidecar",
    "RACK_LLM_LLAMA_SIDECAR",
    "rack-llm/llama-cpp",
    "make-llama-cpp-provider",
    "make-llama-cpp-backend",
    "racket_generate_hf_sidecar",
]

APPROXIMATION_MARKERS = [
    "top-k-approx",
    "top_k_logits_shortlist",
    "racket_generate_hf_sidecar_topk",
]

PLACEHOLDER_MARKERS = [
    "synthetic_offline",
    "synthetic_valid",
    "synthetic_invalid",
    "baseline_not_run",
    "no_model_or_candidate_cache",
    "candidate_from_spec",
]


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def files_under(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in paths:
        if root.is_file():
            files.append(root)
            continue
        files.extend(
            path
            for path in root.rglob("*")
            if path.is_file() and path.suffix in {".py", ".rkt", ".md", ".json"}
        )
    return sorted(files)


def assert_no_markers(path: Path, markers: list[str]) -> None:
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8", errors="ignore")
    found = [marker for marker in markers if marker in text]
    assert not found, f"{path} contains stale markers: {found}"


def test_required_data_paths_are_real_inputs() -> None:
    assert REQUIRED_DATA
    for path in REQUIRED_DATA:
        assert path.exists(), path


def test_preflight_reports_missing_native_backend_without_synthetic_results() -> None:
    env = os.environ.copy()
    env.pop("RACK_LLM_GGUF_MODEL", None)
    completed = subprocess.run(
        [sys.executable, str(RUNNER), "--allow-missing", "--experiment-only", "--no-write"],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    payload = json.loads(completed.stdout)
    assert payload["status"] == "MISSING_BACKEND"
    text = "\n".join(payload["missing"])
    assert "RACK_LLM_GGUF_MODEL" in text
    assert "synthetic" not in text.lower()


def test_preflight_shape() -> None:
    result = preflight()
    assert isinstance(result.ok, bool)
    assert isinstance(result.missing, list)
    assert "repo_root" in result.metadata
    assert "gguf_model_path" in result.metadata


def test_backend_metadata_schema_helper() -> None:
    result = CheckResult(
        ok=False,
        missing=["native library missing"],
        metadata={
            "python": "3.12",
            "model": {"path": "/tmp/model.gguf", "exists": False, "files": {}},
            "packages": {},
        },
    )
    text = missing_markdown(result)
    assert "Missing Real Qwen Backend" in text
    assert "native library missing" in text


def test_strict_json_encodes_nonfinite_weights_for_racket_reader() -> None:
    row = {
        "key": "json-boundary",
        "rule_sets": {
            "clean": [
                {
                    "kind": "ban",
                    "weight": float("-inf"),
                    "pattern_type": "regex",
                    "pattern": "secret",
                }
            ]
        },
    }
    encoded = strict_json_dumps(row, ensure_ascii=False, sort_keys=True)
    assert "-Infinity" in encoded
    assert '"-Infinity"' in encoded
    json.loads(encoded, parse_constant=lambda value: (_ for _ in ()).throw(AssertionError(value)))
    assert math.isinf(float(json.loads(encoded)["rule_sets"]["clean"][0]["weight"]))

    with tempfile.TemporaryDirectory(prefix="rack-llm-json-test-") as tmp:
        path = Path(tmp) / "rows.jsonl"
        write_jsonl(path, [row])
        completed = subprocess.run(
            [
                "racket",
                "-e",
                (
                    "(require json racket/string) "
                    f"(call-with-input-file {json.dumps(str(path))} "
                    "(lambda (in) "
                    "(for ([line (in-lines in)] #:when (not (string=? \"\" (string-trim line)))) "
                    "(string->jsexpr line))))"
                ),
            ],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        assert completed.returncode == 0, completed.stderr


def test_active_experiment_code_uses_no_old_sidecar_or_topk_backend() -> None:
    allowed_legacy_files = {
        EXPERIMENT_DIR / "code" / "test_real_model_benchmark.py",
    }
    for path in files_under(ACTIVE_CODE_DIRS):
        if path in allowed_legacy_files:
            continue
        assert_no_markers(path, OLD_BACKEND_MARKERS + APPROXIMATION_MARKERS)


def test_final_artifacts_use_no_legacy_or_placeholder_markers() -> None:
    for path in FINAL_ARTIFACTS:
        assert_no_markers(path, OLD_BACKEND_MARKERS + APPROXIMATION_MARKERS + PLACEHOLDER_MARKERS)


def test_backend_metadata_artifact_is_native_gguf() -> None:
    if not ROOT_BACKEND_METADATA.exists():
        return
    payload = json.loads(ROOT_BACKEND_METADATA.read_text(encoding="utf-8"))
    model = payload.get("model", {})
    assert model.get("exists") is True
    assert str(model.get("path", "")).endswith(".gguf")
    assert payload.get("backend") == "llama.cpp-native"


def test_ours_soft_generation_samples_are_native_full_vocab_runs() -> None:
    path = EXPERIMENT_DIR / "results" / "012_ours_soft_generation_raw.jsonl"
    if not path.exists():
        return
    rows = read_jsonl(path)
    assert rows
    assert all(row.get("generation_backend") == "racket_generate_native_llama_cpp_full_vocab" for row in rows)
    assert all(row.get("provider_mode") == "exact-full-vocab" for row in rows)
    assert all(row.get("approximation") == "none" for row in rows)


def test_real_soft_benchmark_uses_native_ours_rows() -> None:
    path = REPO_ROOT / "data" / "012_soft_real_raw.jsonl"
    if not path.exists():
        return
    rows = read_jsonl(path)
    ours = [row for row in rows if str(row.get("method", "")).startswith("ours_")]
    assert ours
    assert all(row.get("generation_backend") == "racket_generate_native_llama_cpp_full_vocab" for row in ours)
    assert all(row.get("provider_mode") == "exact-full-vocab" for row in ours)
    assert all(row.get("approximation") == "none" for row in ours)


def test_repro_package_hashes_final_artifacts() -> None:
    if not (CONFIG_LOCK.exists() and ARTIFACT_MANIFEST.exists() and REPRODUCE.exists()):
        return
    config = json.loads(CONFIG_LOCK.read_text(encoding="utf-8"))
    manifest = json.loads(ARTIFACT_MANIFEST.read_text(encoding="utf-8"))
    reproduce = REPRODUCE.read_text(encoding="utf-8")
    assert config["benchmark"]["pilot_outputs_005_011_are_paper_grade"] is False
    assert manifest["artifact_count"] == len(manifest["artifacts"])
    assert all(item["sha256"] and item["bytes"] > 0 for item in manifest["artifacts"])
    assert "HF sidecar" not in reproduce
    assert "top-k" not in reproduce.lower()


def main() -> int:
    tests = [
        test_required_data_paths_are_real_inputs,
        test_preflight_reports_missing_native_backend_without_synthetic_results,
        test_preflight_shape,
        test_backend_metadata_schema_helper,
        test_strict_json_encodes_nonfinite_weights_for_racket_reader,
        test_active_experiment_code_uses_no_old_sidecar_or_topk_backend,
        test_final_artifacts_use_no_legacy_or_placeholder_markers,
        test_backend_metadata_artifact_is_native_gguf,
        test_ours_soft_generation_samples_are_native_full_vocab_runs,
        test_real_soft_benchmark_uses_native_ours_rows,
        test_repro_package_hashes_final_artifacts,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
