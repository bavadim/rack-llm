#!/usr/bin/env python3
"""Tests for the real-model benchmark gate."""

from __future__ import annotations

import json
import os
import base64
import csv
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from hf_logits_sidecar import encode_float64_b64
from run_real_model_benchmark import EXPERIMENT_DIR, REQUIRED_DATA, preflight
from run_hard_runtime_benchmark import RESULTS_DIR, runtime_supported, summarize
from setup_real_backend import CheckResult, missing_markdown


REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = EXPERIMENT_DIR / "code" / "run_real_model_benchmark.py"
ROOT_BACKEND_METADATA = REPO_ROOT / "data" / "012_backend_metadata.json"
ROOT_SIDECAR_SMOKE = REPO_ROOT / "data" / "012_sidecar_smoke.json"
ROOT_RACKET_SIDECAR_SMOKE = REPO_ROOT / "data" / "012_racket_sidecar_smoke.json"
HARD_RUNNER = EXPERIMENT_DIR / "code" / "run_hard_runtime_benchmark.py"
SOFT_RULE_BUILDER = EXPERIMENT_DIR / "code" / "build_soft_rules_012.py"
SOFT_POOL = REPO_ROOT / "data" / "012_soft_candidate_pool.jsonl"
SOFT_AUDIT_FAILURES = REPO_ROOT / "data" / "012_soft_rule_audit_failures.md"
SOFT_AUDITED = REPO_ROOT / "data" / "012_soft_ifbench_rules_audited.jsonl"
SOFT_RACKET_AUDITED = REPO_ROOT / "data" / "012_soft_ifbench_rules_audited_racket.jsonl"
SOFT_RACKET_REPORT = EXPERIMENT_DIR / "results" / "025_soft_racket_dsl_dataset_report.json"
SOFT_RULE_FEATURES = REPO_ROOT / "data" / "012_soft_rule_feature_table.jsonl"
SOFT_RULE_CALIBRATION = REPO_ROOT / "data" / "012_soft_rule_calibration.csv"
SOFT_RULE_CORRELATIONS = REPO_ROOT / "data" / "012_soft_rule_correlations.csv"
SOFT_CALIBRATED = REPO_ROOT / "data" / "012_soft_ifbench_rules_calibrated.jsonl"
SOFT_CALIBRATION_REPORT = EXPERIMENT_DIR / "results" / "027_soft_rule_calibration_report.json"
OURS_SOFT_SMOKE = EXPERIMENT_DIR / "results" / "019_ours_soft_smoke_raw.jsonl"
OURS_SOFT_GENERATION = EXPERIMENT_DIR / "results" / "012_ours_soft_generation_raw.jsonl"
SOFT_REAL_RAW = REPO_ROOT / "data" / "012_soft_real_raw.jsonl"
SOFT_REAL_SUMMARY = REPO_ROOT / "data" / "012_soft_real_summary.csv"
SOFT_MISSING = REPO_ROOT / "data" / "012_missing_runs.json"
CONFIG_LOCK = EXPERIMENT_DIR / "config.lock.json"
ARTIFACT_MANIFEST = EXPERIMENT_DIR / "ARTIFACT_MANIFEST.json"
REPRODUCE = EXPERIMENT_DIR / "REPRODUCE.md"


def test_required_data_paths_are_real_inputs() -> None:
    assert REQUIRED_DATA
    for path in REQUIRED_DATA:
        assert path.exists(), path


def test_preflight_reports_missing_backend_without_synthetic_results() -> None:
    env = os.environ.copy()
    env.pop("RACK_LLM_MODEL_PATH", None)
    env.pop("RACK_LLM_LLAMA_SIDECAR", None)
    completed = subprocess.run(
        [sys.executable, str(RUNNER), "--allow-missing", "--experiment-only"],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    payload = json.loads(completed.stdout)
    assert payload["status"] == "MISSING_BACKEND"
    missing = EXPERIMENT_DIR / "results" / "MISSING_BACKEND.md"
    assert missing.exists()
    text = missing.read_text(encoding="utf-8")
    assert "RACK_LLM_MODEL_PATH" in text
    assert "synthetic" not in text.lower()
    existing_soft = EXPERIMENT_DIR / "results" / "012_soft_real_raw.jsonl"
    if existing_soft.exists():
        head = "\n".join(existing_soft.read_text(encoding="utf-8").splitlines()[:8])
        assert "synthetic" not in head.lower()


def test_preflight_shape() -> None:
    result = preflight()
    assert isinstance(result.ok, bool)
    assert isinstance(result.missing, list)
    assert "repo_root" in result.metadata


def test_backend_metadata_schema_helper() -> None:
    result = CheckResult(
        ok=False,
        missing=["venv python missing"],
        metadata={
            "python": "3.12",
            "venv": ".venv-realbench",
            "model": {"path": "/tmp/model", "exists": False, "files": {}},
            "packages": {"torch": None},
        },
    )
    text = missing_markdown(result)
    assert "Missing Real Qwen Backend" in text
    assert "venv python missing" in text
    assert "torch" in text


def test_backend_metadata_artifact_is_namespaced() -> None:
    assert ROOT_BACKEND_METADATA.exists()
    payload = json.loads(ROOT_BACKEND_METADATA.read_text(encoding="utf-8"))
    assert payload["model"]["exists"] is True
    assert "Qwen3.5-4B" in payload["model"]["path"]
    assert payload["smoke"]["cuda_available"] is True
    assert not (REPO_ROOT / "data" / "backend_metadata.json").exists()


def test_sidecar_float64be_encoding_roundtrip() -> None:
    encoded = encode_float64_b64(np.asarray([1.0, -2.5, 0.125], dtype=np.float32))
    decoded = np.frombuffer(base64.b64decode(encoded), dtype=">f8")
    assert decoded.tolist() == [1.0, -2.5, 0.125]


def test_sidecar_smoke_output_schema() -> None:
    assert ROOT_SIDECAR_SMOKE.exists()
    payload = json.loads(ROOT_SIDECAR_SMOKE.read_text(encoding="utf-8"))
    assert payload["ok"] is True
    assert payload["roundtrip_prefix_match"] is True
    assert payload["token_count"] > 0
    assert payload["logits_vocab_size"] > 1000
    assert payload["sample_generated_tokens"] > 0


def test_racket_sidecar_smoke_output_schema() -> None:
    assert ROOT_RACKET_SIDECAR_SMOKE.exists()
    payload = json.loads(ROOT_RACKET_SIDECAR_SMOKE.read_text(encoding="utf-8"))
    assert payload["ok"] is True
    assert payload["roundtrip_ok"] is True
    assert payload["generation_status"] == "found"
    assert payload["generated_tokens"] > 0
    assert payload["generated_text"] in {" yes", " no"}


def test_hard_runtime_no_witness_mode() -> None:
    source = HARD_RUNNER.read_text(encoding="utf-8")
    assert "candidate_from_spec" not in source
    assert "witness" not in source.lower()


def test_verifier_not_used_during_generation() -> None:
    source = HARD_RUNNER.read_text(encoding="utf-8")
    for name in ["run_ours", "run_guidance", "run_outlines"]:
        body = source.split(f"def {name}", 1)[1].split("\ndef ", 1)[0]
        assert "official_check(" not in body
        assert "load_registry()" not in body


def test_guidance_outlines_are_real_imports() -> None:
    source = HARD_RUNNER.read_text(encoding="utf-8")
    assert "import guidance" in source
    assert "guidance.select" in source
    assert "import outlines" in source
    assert "outlines.regex" in source
    assert "outlines_model(" in source


def test_unsupported_is_explicit() -> None:
    class RegexOnly:
        choices = None
        regex = r"[A-Z]+"

    supported, reason = runtime_supported(RegexOnly())  # type: ignore[arg-type]
    assert supported is True
    assert reason == ""

    class EmptySpec:
        choices = None
        regex = None

    supported, reason = runtime_supported(EmptySpec())  # type: ignore[arg-type]
    assert supported is False
    assert reason.startswith("UNSUPPORTED_CONSTRAINT")


def test_hard_raw_has_no_synthetic_source() -> None:
    raw_path = RESULTS_DIR / "012_hard_real_raw.jsonl"
    if not raw_path.exists():
        return
    rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert rows
    assert all(row["source"] == "real_runtime" for row in rows)
    assert not any("synthetic" in json.dumps(row).lower() for row in rows)


def test_hard_summary_matches_raw_counts() -> None:
    raw_path = RESULTS_DIR / "012_hard_real_raw.jsonl"
    summary_path = RESULTS_DIR / "012_hard_real_summary.csv"
    if not raw_path.exists() or not summary_path.exists():
        return
    rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    expected = {row["method"]: str(row["n"]) for row in summarize(rows)}
    with summary_path.open("r", encoding="utf-8", newline="") as handle:
        observed = {row["method"]: row["n"] for row in csv.DictReader(handle)}
    assert observed == expected


def test_official_verifier_column_present() -> None:
    raw_path = RESULTS_DIR / "012_hard_real_raw.jsonl"
    if not raw_path.exists():
        return
    rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert rows
    assert all("official_verifier" in row for row in rows)


def test_all_paired_supported_rows_have_all_methods() -> None:
    raw_path = RESULTS_DIR / "012_hard_real_raw.jsonl"
    if not raw_path.exists():
        return
    rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    by_pair: dict[tuple[str, int], set[str]] = {}
    for row in rows:
        by_pair.setdefault((row["key"], int(row["seed"])), set()).add(row["method"])
    assert by_pair
    assert all(methods == {"ours_hard", "guidance_hard", "outlines_hard"} for methods in by_pair.values())


def test_outlines_hard_has_zero_wrong_and_error_rates() -> None:
    summary_path = REPO_ROOT / "data" / "012_hard_real_summary.csv"
    if not summary_path.exists():
        return
    with summary_path.open("r", encoding="utf-8", newline="") as handle:
        rows = {row["method"]: row for row in csv.DictReader(handle)}
    outlines = rows["outlines_hard"]
    assert float(outlines["solve_rate"]) == 1.0
    assert float(outlines["wrong_rate"]) == 0.0
    assert float(outlines["error_rate"]) == 0.0


def test_repeat_span_key_285_not_character_slice() -> None:
    raw_path = REPO_ROOT / "data" / "012_hard_real_raw.jsonl"
    if not raw_path.exists():
        return
    rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    key_285 = [row for row in rows if row["key"] == "285"]
    assert key_285
    assert {row["text"] for row in key_285} == {"screenplay of a fish being pulled out of the water by"}
    assert not any(row["text"] in {" a descript", " a descri"} for row in key_285)


def test_soft_supported_rows_at_least_250() -> None:
    report = json.loads((RESULTS_DIR / "016_soft_rule_coverage_report.json").read_text(encoding="utf-8"))
    assert report["soft_supported_rows"] >= 250
    assert report["builder_imports_official_verifier"] is False


def test_no_verifier_import_in_soft_rules() -> None:
    source = SOFT_RULE_BUILDER.read_text(encoding="utf-8")
    assert "instructions_registry" not in source
    assert "official_check" not in source
    assert "load_registry" not in source


def test_candidate_pool_has_no_synthetic_source() -> None:
    rows = [json.loads(line) for line in SOFT_POOL.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert rows
    allowed = {"real_qwen_unconstrained", "real_qwen_strict_chat_no_think", "real_qwen_strict_final"}
    assert {row["pool_source"] for row in rows} <= allowed
    assert not any("synthetic_offline" in json.dumps(row).lower() for row in rows)


def test_each_row_has_baseline_or_full_candidate_count() -> None:
    rows = [json.loads(line) for line in SOFT_POOL.read_text(encoding="utf-8").splitlines() if line.strip()]
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["key"]] = counts.get(row["key"], 0) + 1
    assert len(counts) >= 250
    assert min(counts.values()) >= 80
    assert max(counts.values()) <= 192
    assert any(count == 80 for count in counts.values())


def test_candidate_pool_has_verifier_labels() -> None:
    rows = [json.loads(line) for line in SOFT_POOL.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert rows
    assert all("official_verifier" in row for row in rows)
    assert any(row["official_verifier"] for row in rows)


def test_candidate_metadata_has_model_and_seed() -> None:
    rows = [json.loads(line) for line in SOFT_POOL.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert rows
    for row in rows[:32]:
        assert row["generation_metadata"]["model"]
        assert isinstance(row["seed"], int)


def test_soft_audit_passed_real_pool_gate() -> None:
    text = SOFT_AUDIT_FAILURES.read_text(encoding="utf-8")
    audited = [json.loads(line) for line in SOFT_AUDITED.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert "required_survivors: 150" in text
    assert len(audited) >= 150
    assert "audited_rows: 152" in text


def test_soft_racket_dataset_exists_and_validates() -> None:
    rows = [json.loads(line) for line in SOFT_RACKET_AUDITED.read_text(encoding="utf-8").splitlines() if line.strip()]
    report = json.loads(SOFT_RACKET_REPORT.read_text(encoding="utf-8"))
    assert len(rows) == report["input_rows"] == 152
    assert report["failed_rows"] == 0
    assert report["total_json_rules"] == report["total_racket_watchers"]
    assert report["racket_validation"]["ok"] is True
    assert report["racket_validation"]["validated_sources"] == 152 * 3
    assert report["uses_official_verifier"] is False


def test_soft_racket_dataset_has_no_rule_drops_and_translates_flags() -> None:
    rows = [json.loads(line) for line in SOFT_RACKET_AUDITED.read_text(encoding="utf-8").splitlines() if line.strip()]
    saw_scoped_flag = False
    for row in rows:
        assert {"key", "prompt", "instruction_id_list", "kwargs", "rule_sets", "racket_rule_sets"} <= set(row)
        for noise in ("clean", "noisy_20", "noisy_40"):
            original = row["rule_sets"][noise]
            lowered = row["racket_rule_sets"][noise]
            assert lowered["lowering_status"] == "ok"
            assert lowered["lowering_errors"] == []
            assert len(lowered["watchers"]) == len(original)
            assert lowered["guide_source"].startswith("(text #:max-tokens")
            saw_scoped_flag = saw_scoped_flag or "(?i:" in lowered["guide_source"]
    assert saw_scoped_flag


def test_soft_rule_feature_table_schema() -> None:
    rows = [json.loads(line) for line in SOFT_RULE_FEATURES.read_text(encoding="utf-8").splitlines() if line.strip()]
    report = json.loads(SOFT_CALIBRATION_REPORT.read_text(encoding="utf-8"))
    assert len(rows) == report["feature_rows"] == report["candidate_rows"] * 3
    sample = rows[0]
    assert {"key", "split", "noise", "candidate_id", "official_verifier", "fired_rule_ids", "raw_score", "calibrated_score", "banned"} <= set(sample)
    assert {row["noise"] for row in rows} == {"clean", "noisy_20", "noisy_40"}
    assert {row["split"] for row in rows} == {"dev", "test"}


def test_calibration_outputs_have_no_rule_drops_and_no_test_training() -> None:
    audited = [json.loads(line) for line in SOFT_AUDITED.read_text(encoding="utf-8").splitlines() if line.strip()]
    calibrated = [json.loads(line) for line in SOFT_CALIBRATED.read_text(encoding="utf-8").splitlines() if line.strip()]
    report = json.loads(SOFT_CALIBRATION_REPORT.read_text(encoding="utf-8"))
    assert len(audited) == len(calibrated) == 152
    assert report["uses_test_labels_for_training"] is False
    for before, after in zip(audited, calibrated):
        assert before["key"] == after["key"]
        for noise in ("clean", "noisy_20", "noisy_40"):
            assert len(before["rule_sets"][noise]) == len(after["calibrated_rule_sets"][noise])
            for rule in after["calibrated_rule_sets"][noise]:
                assert "calibration_key" in rule
                assert "calibration_status" in rule
                if rule["kind"] == "ban":
                    assert rule["calibration_status"] == "hard_ban"
                else:
                    assert "calibrated_weight" in rule


def test_calibration_and_correlation_tables_schema() -> None:
    with SOFT_RULE_CALIBRATION.open("r", encoding="utf-8", newline="") as handle:
        calibration_rows = list(csv.DictReader(handle))
    with SOFT_RULE_CORRELATIONS.open("r", encoding="utf-8", newline="") as handle:
        correlation_rows = list(csv.DictReader(handle))
    report = json.loads(SOFT_CALIBRATION_REPORT.read_text(encoding="utf-8"))
    assert len(calibration_rows) == report["calibration_rows"] == 17205
    assert len(correlation_rows) == report["correlation_rows"]
    assert {"calibrated_weight", "calibration_key", "calibration_status"} <= set(calibration_rows[0])
    assert {"jaccard", "phi", "n11", "n10", "n01", "n00", "duplicate_candidate"} <= set(correlation_rows[0])
    assert any(row["duplicate_candidate"] == "True" for row in correlation_rows)


def test_log_odds_and_correlation_formula_sanity() -> None:
    from calibrate_soft_rules_012 import Stat, calibrated_from_stat, correlation_row

    stat = Stat()
    for fired, ok in [(True, True), (True, True), (True, False), (False, False), (False, False)]:
        stat.update(fired, ok)
    assert calibrated_from_stat(stat) > 0

    row = correlation_row("k", "clean", "a", "b", 0b011, 0b110, 3)
    assert row["n11"] == 1
    assert row["n10"] == 1
    assert row["n01"] == 1
    assert row["n00"] == 0
    assert row["jaccard"] == 1 / 3


def test_calibration_report_compares_raw_and_calibrated_scores() -> None:
    report = json.loads(SOFT_CALIBRATION_REPORT.read_text(encoding="utf-8"))
    assert set(report["noise"]) == {"clean", "noisy_20", "noisy_40"}
    for noise, payload in report["noise"].items():
        assert "raw" in payload and "calibrated" in payload
        assert "AUROC" in payload["raw"]["dev"]
        assert "AUPRC" in payload["calibrated"]["test"]
        assert "risk_coverage" in payload["calibrated"]["test"]
    assert report["noise"]["noisy_20"]["calibrated"]["test"]["AUROC"] > report["noise"]["noisy_20"]["raw"]["test"]["AUROC"]


def test_ours_soft_smoke_uses_racket_not_candidate_pool() -> None:
    rows = [json.loads(line) for line in OURS_SOFT_SMOKE.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(rows) == 15
    assert {row["noise"] for row in rows} == {"clean", "noisy_20", "noisy_40"}
    assert len({row["key"] for row in rows}) == 5
    assert all(row["generation_backend"] == "racket_generate_hf_sidecar" for row in rows)
    assert not any(row["uses_candidate_pool"] for row in rows)
    assert not any(row["uses_official_verifier"] for row in rows)
    assert all(row["text"] or row["failure_reason"] for row in rows)


def test_ours_soft_generation_samples_are_real_racket_full_vocab_runs() -> None:
    rows = [json.loads(line) for line in OURS_SOFT_GENERATION.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(rows) == 152 * 3 * 2 * 16
    assert {row["method"] for row in rows} == {"ours_soft_decoding", "ours_hybrid_decoding"}
    assert {row["noise"] for row in rows} == {"clean", "noisy_20", "noisy_40"}
    assert {int(row["sample_index"]) for row in rows} == set(range(16))
    assert all(row["generation_backend"] == "racket_generate_hf_sidecar_full_vocab" for row in rows)
    assert all(row["provider_mode"] == "exact-full-vocab" for row in rows)
    assert all(row["approximation"] == "none" for row in rows)
    assert not all(int(row.get("generated_tokens") or 0) == 1 for row in rows)
    assert not any(row["uses_candidate_pool"] for row in rows)
    assert not any(row["uses_official_verifier_for_selection"] for row in rows)
    by_key_noise: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        by_key_noise.setdefault((row["key"], row["noise"]), []).append(row)
    assert len(by_key_noise) == 152 * 3
    assert all(any(item["status"] == "found" and item["text"] for item in group) for group in by_key_noise.values())


def test_real_soft_benchmark_outputs_include_ours_generation_runs() -> None:
    raw = [json.loads(line) for line in SOFT_REAL_RAW.read_text(encoding="utf-8").splitlines() if line.strip()]
    missing = json.loads(SOFT_MISSING.read_text(encoding="utf-8"))
    assert raw
    assert SOFT_REAL_SUMMARY.exists()
    assert missing == []
    pool_rows = [row for row in raw if not row["method"].startswith("ours_")]
    ours_rows = [row for row in raw if row["method"].startswith("ours_")]
    assert pool_rows and ours_rows
    assert all(row["generation_backend"] == "real_qwen_candidate_pool" for row in pool_rows[:256])
    assert not any("synthetic" in " ".join(row["pool_sources"]).lower() for row in pool_rows[:256])
    assert len(ours_rows) == 152 * 3 * 4 * 2 * 2
    assert {row["method"] for row in ours_rows} == {"ours_soft_decoding", "ours_hybrid_decoding"}
    assert {row["noise"] for row in ours_rows} == {"clean", "noisy_20", "noisy_40"}
    assert {int(row["N"]) for row in ours_rows} == {1, 4, 8, 16}
    assert {row["policy"] for row in ours_rows} == {"always", "risk_target:0.05"}
    assert len({row["example_id"] for row in ours_rows}) == 152
    assert not any(row["uses_candidate_pool"] for row in ours_rows)
    assert not any(row["uses_official_verifier_for_selection"] for row in ours_rows)
    assert all(row["provider_mode"] == "exact-full-vocab" for row in ours_rows)
    assert all(row["approximation"] == "none" for row in ours_rows)
    assert all(row["rule_set_hash"] for row in ours_rows)
    assert any(row["returned"] and row["text"] for row in ours_rows)
    assert not any(row["uses_official_verifier_for_selection"] for row in raw if row["method"] != "oracle_verifier_selection")


def test_soft_summary_includes_ours_methods() -> None:
    with SOFT_REAL_SUMMARY.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    methods = {row["method"] for row in rows}
    assert {"ours_soft_decoding", "ours_hybrid_decoding"} <= methods
    ours = [row for row in rows if row["method"] in {"ours_soft_decoding", "ours_hybrid_decoding"}]
    assert ours
    assert {row["noise"] for row in ours} == {"clean", "noisy_20", "noisy_40"}
    assert {int(row["N"]) for row in ours} == {1, 4, 8, 16}
    assert {row["policy"] for row in ours} == {"always", "risk_target:0.05"}


def test_repro_package_hashes_final_artifacts() -> None:
    config = json.loads(CONFIG_LOCK.read_text(encoding="utf-8"))
    manifest = json.loads(ARTIFACT_MANIFEST.read_text(encoding="utf-8"))
    reproduce = REPRODUCE.read_text(encoding="utf-8")
    assert config["benchmark"]["pilot_outputs_005_011_are_paper_grade"] is False
    assert config["model"]["exists"] is True
    assert manifest["artifact_count"] == len(manifest["artifacts"])
    assert all(item["sha256"] and item["bytes"] > 0 for item in manifest["artifacts"])
    assert "Pilot artifacts `005-011` are non-paper-grade" in reproduce


def main() -> int:
    tests = [
        test_required_data_paths_are_real_inputs,
        test_preflight_reports_missing_backend_without_synthetic_results,
        test_preflight_shape,
        test_backend_metadata_schema_helper,
        test_backend_metadata_artifact_is_namespaced,
        test_sidecar_float64be_encoding_roundtrip,
        test_sidecar_smoke_output_schema,
        test_racket_sidecar_smoke_output_schema,
        test_hard_runtime_no_witness_mode,
        test_verifier_not_used_during_generation,
        test_guidance_outlines_are_real_imports,
        test_unsupported_is_explicit,
        test_hard_raw_has_no_synthetic_source,
        test_hard_summary_matches_raw_counts,
        test_official_verifier_column_present,
        test_all_paired_supported_rows_have_all_methods,
        test_outlines_hard_has_zero_wrong_and_error_rates,
        test_repeat_span_key_285_not_character_slice,
        test_soft_supported_rows_at_least_250,
        test_no_verifier_import_in_soft_rules,
        test_candidate_pool_has_no_synthetic_source,
        test_each_row_has_baseline_or_full_candidate_count,
        test_candidate_pool_has_verifier_labels,
        test_candidate_metadata_has_model_and_seed,
        test_soft_audit_passed_real_pool_gate,
        test_soft_racket_dataset_exists_and_validates,
        test_soft_racket_dataset_has_no_rule_drops_and_translates_flags,
        test_soft_rule_feature_table_schema,
        test_calibration_outputs_have_no_rule_drops_and_no_test_training,
        test_calibration_and_correlation_tables_schema,
        test_log_odds_and_correlation_formula_sanity,
        test_calibration_report_compares_raw_and_calibrated_scores,
        test_ours_soft_smoke_uses_racket_not_candidate_pool,
        test_ours_soft_generation_samples_are_real_racket_full_vocab_runs,
        test_real_soft_benchmark_outputs_include_ours_generation_runs,
        test_soft_summary_includes_ours_methods,
        test_repro_package_hashes_final_artifacts,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
