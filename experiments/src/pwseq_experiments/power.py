from __future__ import annotations

import json
import math
from collections import Counter, defaultdict

import numpy as np
from scipy.stats import norm

from .common import (
    ARTIFACTS, CONFIG_PATH, DATA, assert_frozen, file_hash, load_config,
    read_jsonl, run_state, set_run_state, stable_hash, write_json,
)


PRIMARY_METHODS = ("exact_pwsg", "posterior_best_of_b")
POWER_BUDGET = 8
POWER_COMPARISON = "exact_pwsg-minus-posterior_best_of_b"


def _frozen_test_design() -> tuple[list[dict], list[str], int]:
    test_rows = read_jsonl(DATA / "test.jsonl")
    dataset_manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
    families = sorted(map(str, dataset_manifest.get("families", [])))
    counts = Counter(str(row["family"]) for row in test_rows)
    if not families or set(counts) != set(families):
        raise RuntimeError("test families do not match the frozen dataset manifest")
    family_sizes = set(counts.values())
    if len(family_sizes) != 1 or next(iter(family_sizes)) <= 0:
        raise RuntimeError("power analysis requires a uniform non-empty test split")
    return test_rows, families, next(iter(family_sizes))


def _require_complete_calibration(families: list[str]) -> None:
    path = ARTIFACTS / "calibrations" / "main_design" / "noise_00" / "manifest.json"
    if not path.is_file():
        raise RuntimeError(f"power analysis requires calibration manifest: {path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    cohorts = manifest.get("cohorts")
    if not isinstance(cohorts, dict) or set(cohorts) != set(families):
        raise RuntimeError("calibration manifest does not contain exactly all dataset families")
    failed = sorted(
        family for family in families
        if not isinstance(cohorts[family], dict) or cohorts[family].get("status") != "OK"
    )
    if failed:
        raise RuntimeError(f"calibration cohorts are not all OK: {failed}")


def _ceil_to_10(value: float) -> int:
    return int(math.ceil(value / 10.0) * 10)


def power_analysis() -> dict:
    """Dev-only paired design calculation; never reads a test label."""
    assert_frozen()
    if run_state() != "DESIGN_COMPLETE":
        raise RuntimeError(f"power analysis requires DESIGN_COMPLETE state, got {run_state()}")
    config = load_config()
    test_rows, families, prompts_per_family = _frozen_test_design()
    _require_complete_calibration(families)
    raw = ARTIFACTS / "results" / "main_design_noise_00_generation_raw.jsonl"
    thresholds = ARTIFACTS / "thresholds" / "main_design_noise_00.jsonl"
    if not raw.exists() or not thresholds.exists():
        raise RuntimeError("power analysis requires completed dev generation and thresholds")
    tau = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(thresholds)
    }
    for method in PRIMARY_METHODS:
        decision = tau.get((method, POWER_BUDGET))
        if decision is None or decision.get("source_split") != "dev":
            raise RuntimeError(f"missing dev-only threshold for {method}/{POWER_BUDGET}")
    raw_rows = read_jsonl(raw)
    calibration_errors = [
        row for row in raw_rows
        if row.get("method") in PRIMARY_METHODS
        and row.get("calibration_status") == "ERROR"
    ]
    if calibration_errors:
        row = calibration_errors[0]
        raise RuntimeError(
            "power analysis rejects calibration errors: "
            f"{row['method']}/{row.get('family')}/{row.get('prompt_id')}"
        )
    by_method_prompt: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for row in raw_rows:
        if (
            row["split"] == "dev"
            and int(row["budget"]) == POWER_BUDGET
            and row["method"] in PRIMARY_METHODS
        ):
            by_method_prompt[row["method"]][row["prompt_id"]].append(row)
    dev_rows = read_jsonl(DATA / "dev.jsonl")
    expected_prompts = {row["id"]: row["family"] for row in dev_rows}
    if len(expected_prompts) != len(dev_rows):
        raise RuntimeError("dev dataset contains duplicate prompt ids")
    expected = set(map(int, config["generation_seeds"]))
    for method in PRIMARY_METHODS:
        actual_prompts = set(by_method_prompt[method])
        if actual_prompts != set(expected_prompts):
            raise RuntimeError(
                f"invalid dev prompt cohort for {method}: "
                f"missing={len(set(expected_prompts) - actual_prompts)}, "
                f"extra={len(actual_prompts - set(expected_prompts))}"
            )
    differences: dict[str, list[float]] = defaultdict(list)
    for prompt, family in sorted(expected_prompts.items()):
        ours = by_method_prompt["exact_pwsg"][prompt]
        baseline = by_method_prompt["posterior_best_of_b"][prompt]
        def solve(values: list[dict], method: str) -> float:
            seeds = [int(row["seed"]) for row in values]
            if set(seeds) != expected or len(seeds) != len(expected):
                raise RuntimeError(f"invalid dev seed cohort: {method}/{prompt}")
            if any(row["family"] != family for row in values):
                raise RuntimeError(f"dev family mismatch: {method}/{prompt}")
            decision = tau[(method, POWER_BUDGET)]
            mode = decision["accept_if"]
            return float(np.mean([
                row["outcome"] == "FOUND_OK"
                and (
                    mode == "always"
                    or (mode == "confidence_gte" and float(row["confidence"]) >= float(decision["threshold"]))
                )
                for row in values
            ]))
        differences[family].append(solve(ours, "exact_pwsg") - solve(baseline, "posterior_best_of_b"))
    target = float(config["power_target_effect"])
    if target <= 0.0:
        raise RuntimeError("power_target_effect must be positive")
    alpha = float(config["power_alpha"])
    desired = float(config["power_target"])
    if set(differences) != set(families):
        raise RuntimeError("dev families do not match the frozen dataset manifest")
    variance = sum(
        float(np.var(values, ddof=1)) / prompts_per_family
        for values in differences.values() if len(values) > 1
    ) / max(1, len(differences)) ** 2
    standard_error = math.sqrt(variance)
    power = float(norm.cdf(target / standard_error - norm.ppf(1 - alpha / 2))) if standard_error else 1.0
    mde = (
        (norm.ppf(1 - alpha / 2) + norm.ppf(desired)) * standard_error
        if standard_error else 0.0
    )
    required_prompts_per_family = _ceil_to_10(
        prompts_per_family * (float(mde) / target) ** 2
    )
    result = {
        "source_split": "dev", "gold_test_labels_read": False,
        "comparison": POWER_COMPARISON,
        "budget": POWER_BUDGET, "target_effect": target, "alpha": alpha,
        "desired_power": desired, "test_size_is_fixed": True,
        "test_prompts": len(test_rows), "test_families": families,
        "prompts_per_family": prompts_per_family,
        "dataset_revision": json.loads(
            (DATA / "manifest.json").read_text(encoding="utf-8")
        ).get("experiment_revision"),
        "dataset_manifest_sha256": file_hash(DATA / "manifest.json"),
        "test_dataset_sha256": file_hash(DATA / "test.jsonl"),
        "calibration_manifest_sha256": file_hash(
            ARTIFACTS / "calibrations" / "main_design" / "noise_00" / "manifest.json"
        ),
        "required_prompts_per_family": required_prompts_per_family,
        "standard_error": standard_error, "achieved_power": power,
        "minimum_detectable_effect": float(mde),
    }
    write_json(ARTIFACTS / "design" / "power_mde.json", result)
    return result


def record_design() -> dict:
    """Record a dev-only design decision without touching the frozen dataset."""
    assert_frozen()
    if run_state() != "DESIGN_COMPLETE":
        raise RuntimeError(f"record-design requires DESIGN_COMPLETE state, got {run_state()}")
    path = ARTIFACTS / "design" / "power_mde.json"
    if not path.is_file():
        raise RuntimeError("run the dev-only power analysis first")
    result = json.loads(path.read_text(encoding="utf-8"))
    if result.get("gold_test_labels_read") is not False:
        raise RuntimeError("design artifact does not prove test-label blindness")
    config = load_config()
    desired = float(config["power_target"])
    protocol = {
        "source_split": "dev",
        "comparison": POWER_COMPARISON,
        "budget": POWER_BUDGET,
        "target_effect": float(config["power_target_effect"]),
        "alpha": float(config["power_alpha"]),
        "desired_power": desired,
    }
    if any(result.get(key) != value for key, value in protocol.items()):
        raise RuntimeError("design artifact power-protocol mismatch")
    achieved = float(result.get("achieved_power", -math.inf))
    if not math.isfinite(achieved) or achieved < desired:
        raise RuntimeError(
            f"achieved power {result.get('achieved_power')} is below required {desired}"
        )
    test_rows, families, prompts_per_family = _frozen_test_design()
    _require_complete_calibration(families)
    manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
    calibration_manifest = (
        ARTIFACTS / "calibrations" / "main_design" / "noise_00" / "manifest.json"
    )
    if (
        result.get("test_prompts") != len(test_rows)
        or result.get("test_families") != families
        or result.get("prompts_per_family") != prompts_per_family
        or result.get("dataset_revision") != manifest.get("experiment_revision")
        or result.get("dataset_manifest_sha256") != file_hash(DATA / "manifest.json")
        or result.get("test_dataset_sha256") != file_hash(DATA / "test.jsonl")
        or result.get("calibration_manifest_sha256") != file_hash(calibration_manifest)
    ):
        raise RuntimeError("design artifact does not match the frozen test design")
    config["confirmatory_design"] = {
        "status": "finalized",
        "source_run_id": ARTIFACTS.name,
        "source_split": "dev",
        "gold_test_labels_read": False,
        "power_artifact_sha256": file_hash(path),
        "decision_sha256": stable_hash(result),
        "frozen_test_prompts": len(test_rows),
        "frozen_test_prompts_per_family": prompts_per_family,
        "frozen_test_families": families,
        "dataset_revision": result.get("dataset_revision"),
        "dataset_manifest_sha256": file_hash(DATA / "manifest.json"),
        "test_dataset_sha256": file_hash(DATA / "test.jsonl"),
        "calibration_manifest_sha256": file_hash(calibration_manifest),
    }
    write_json(CONFIG_PATH, config)
    set_run_state("SUPERSEDED", reason="dev design recorded into a new confirmatory config revision")
    return config["confirmatory_design"]
