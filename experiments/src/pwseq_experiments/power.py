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
from .metrics import common_coverage_metrics, selective_curve
from .reporting import prompt_generation_records


PRIMARY_METHODS = ("posterior_best_of_b", "equal_score_best_of_b")
POWER_BUDGET = 8
POWER_COMPARISON = "posterior_best_of_b-minus-equal_score_best_of_b"
POWER_METRIC = "macro_normalized_common_coverage_paurc"
FAVORABLE_DIRECTION = "less_than_zero"


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


def _calibration_manifest_status(families: list[str]) -> dict[str, object]:
    """Validate calibration provenance and report scientific fit failures."""
    path = ARTIFACTS / "calibrations" / "main_design" / "noise_00" / "manifest.json"
    if not path.is_file():
        raise RuntimeError(f"power analysis requires calibration manifest: {path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    cohorts = manifest.get("cohorts")
    if not isinstance(cohorts, dict) or set(cohorts) != set(families):
        raise RuntimeError("calibration manifest does not contain exactly all dataset families")
    if any(not isinstance(cohorts[family], dict) for family in families):
        raise RuntimeError("calibration manifest contains a malformed cohort record")
    statuses = {family: cohorts[family].get("status") for family in families}
    if any(status not in {"OK", "ERROR"} for status in statuses.values()):
        raise RuntimeError("calibration manifest contains an unknown cohort status")
    failed = sorted(family for family, status in statuses.items() if status == "ERROR")
    return {
        "calibration_status": "DEGRADED" if failed else "OK",
        "calibration_problem_families": failed,
        "calibration_problem_family_count": len(failed),
    }


def _ceil_to_10(value: float) -> int:
    return int(math.ceil(value / 10.0) * 10)


def power_analysis() -> dict:
    """Dev-only paired design calculation; never reads a test label."""
    assert_frozen()
    if run_state() != "DESIGN_COMPLETE":
        raise RuntimeError(f"power analysis requires DESIGN_COMPLETE state, got {run_state()}")
    config = load_config()
    test_rows, families, prompts_per_family = _frozen_test_design()
    calibration = _calibration_manifest_status(families)
    raw = ARTIFACTS / "results" / "main_design_noise_00_generation_raw.jsonl"
    if not raw.exists():
        raise RuntimeError("power analysis requires completed dev generation")
    raw_rows = read_jsonl(raw)
    calibration_errors = [
        row for row in raw_rows
        if row.get("method") in PRIMARY_METHODS
        and row.get("calibration_status") == "ERROR"
    ]
    row_error_families = sorted({
        str(row["family"]) for row in calibration_errors if row.get("family") is not None
    })
    problem_families = sorted(set(
        list(calibration["calibration_problem_families"]) + row_error_families
    ))
    calibration.update({
        "calibration_status": "DEGRADED" if problem_families else "OK",
        "calibration_problem_families": problem_families,
        "calibration_problem_family_count": len(problem_families),
        "calibration_error_row_count": len(calibration_errors),
    })
    expected = set(map(int, config["generation_seeds"]))
    records = prompt_generation_records([
        row for row in raw_rows
        if row["split"] == "dev" and int(row["budget"]) == POWER_BUDGET
        and row["method"] in PRIMARY_METHODS
    ], expected_seeds=expected)
    by_method_prompt: dict[str, dict[str, dict]] = defaultdict(dict)
    for row in records:
        by_method_prompt[str(row["method"])][str(row["prompt_id"])] = row
    dev_rows = read_jsonl(DATA / "dev.jsonl")
    expected_prompts = {row["id"]: row["family"] for row in dev_rows}
    if len(expected_prompts) != len(dev_rows):
        raise RuntimeError("dev dataset contains duplicate prompt ids")
    for method in PRIMARY_METHODS:
        actual_prompts = set(by_method_prompt[method])
        if actual_prompts != set(expected_prompts):
            raise RuntimeError(
                f"invalid dev prompt cohort for {method}: "
                f"missing={len(set(expected_prompts) - actual_prompts)}, "
                f"extra={len(actual_prompts - set(expected_prompts))}"
            )
    prompts_by_family: dict[str, list[str]] = defaultdict(list)
    for prompt, family in sorted(expected_prompts.items()):
        for method in PRIMARY_METHODS:
            if by_method_prompt[method][prompt]["family"] != family:
                raise RuntimeError(f"dev family mismatch: {method}/{prompt}")
        prompts_by_family[str(family)].append(str(prompt))

    def family_difference(family: str, prompts: list[str]) -> float | None:
        curves = {
            method: selective_curve([
                by_method_prompt[method][prompt] for prompt in prompts
            ])
            for method in PRIMARY_METHODS
        }
        metrics = common_coverage_metrics(curves)
        ours = metrics["posterior_best_of_b"]["normalized_partial_aurc"]
        baseline = metrics["equal_score_best_of_b"]["normalized_partial_aurc"]
        if ours is None or baseline is None:
            return None
        return float(ours) - float(baseline)
    target = float(config["power_target_effect"])
    if target <= 0.0:
        raise RuntimeError("power_target_effect must be positive")
    alpha = float(config["power_alpha"])
    desired = float(config["power_target"])
    if set(prompts_by_family) != set(families):
        raise RuntimeError("dev families do not match the frozen dataset manifest")
    usable = {
        family: prompts for family, prompts in prompts_by_family.items()
        if family not in problem_families
    }
    point_values = [
        family_difference(family, prompts) for family, prompts in usable.items()
    ]
    dev_effect = (
        float(np.mean([value for value in point_values if value is not None]))
        if point_values and all(value is not None for value in point_values) else None
    )
    repetitions = int(config.get("bootstrap_repetitions", 10_000))
    rng = np.random.default_rng(int(config.get("dataset_seed", 0)) + 5)
    bootstrap = []
    if usable:
        for _ in range(repetitions):
            values = []
            for family, prompts in usable.items():
                indices = rng.integers(0, len(prompts), size=prompts_per_family)
                value = family_difference(
                    family, [prompts[index] for index in indices],
                )
                if value is None:
                    break
                values.append(value)
            if len(values) == len(usable):
                bootstrap.append(float(np.mean(values)))
    bootstrap_support = len(bootstrap)
    estimable = (
        dev_effect is not None and bootstrap_support >= math.ceil(.95 * repetitions)
        and bootstrap_support > 1
    )
    if estimable:
        standard_error: float | None = float(np.std(bootstrap, ddof=1))
        power: float | None = (
            float(norm.cdf(target / standard_error - norm.ppf(1 - alpha / 2)))
            if standard_error else 1.0
        )
        mde: float | None = (
            (norm.ppf(1 - alpha / 2) + norm.ppf(desired)) * standard_error
            if standard_error else 0.0
        )
        required_prompts_per_family: int | None = _ceil_to_10(
            prompts_per_family * (mde / target) ** 2
        )
    else:
        standard_error = power = mde = required_prompts_per_family = None
    power_status = (
        "ADEQUATE"
        if calibration["calibration_status"] == "OK"
        and power is not None and power >= desired
        else "UNDERPOWERED"
    )
    result = {
        "source_split": "dev", "gold_test_labels_read": False,
        "comparison": POWER_COMPARISON,
        "metric": POWER_METRIC, "favorable_direction": FAVORABLE_DIRECTION,
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
        **calibration,
        "power_status": power_status,
        "power_estimable": estimable,
        "power_family_count": len(usable),
        "dev_effect": dev_effect,
        "bootstrap_repetitions": repetitions,
        "bootstrap_support": bootstrap_support,
        "required_prompts_per_family": required_prompts_per_family,
        "standard_error": standard_error, "achieved_power": power,
        "minimum_detectable_effect": float(mde) if mde is not None else None,
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
        "metric": POWER_METRIC,
        "favorable_direction": FAVORABLE_DIRECTION,
        "budget": POWER_BUDGET,
        "target_effect": float(config["power_target_effect"]),
        "alpha": float(config["power_alpha"]),
        "desired_power": desired,
    }
    if any(result.get(key) != value for key, value in protocol.items()):
        raise RuntimeError("design artifact power-protocol mismatch")
    test_rows, families, prompts_per_family = _frozen_test_design()
    calibration = _calibration_manifest_status(families)
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
    problem_families = result.get("calibration_problem_families")
    error_rows = result.get("calibration_error_row_count")
    if (
        result.get("power_status") not in {"ADEQUATE", "UNDERPOWERED"}
        or result.get("calibration_status") not in {"OK", "DEGRADED"}
        or not isinstance(problem_families, list)
        or problem_families != sorted(set(map(str, problem_families)))
        or not set(problem_families) <= set(families)
        or result.get("calibration_problem_family_count") != len(problem_families)
        or not isinstance(error_rows, int) or error_rows < 0
        or (result.get("calibration_status") == "OK") != (not problem_families)
        or not set(calibration["calibration_problem_families"]) <= set(problem_families)
    ):
        raise RuntimeError("design artifact has invalid scientific status metadata")
    achieved_value = result.get("achieved_power")
    achieved = float(achieved_value) if achieved_value is not None else None
    expected_power_status = (
        "ADEQUATE"
        if result.get("calibration_status") == "OK"
        and achieved is not None and math.isfinite(achieved) and achieved >= desired
        else "UNDERPOWERED"
    )
    if result["power_status"] != expected_power_status:
        raise RuntimeError("design artifact power status is inconsistent with its estimates")
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
        "power_status": result["power_status"],
        "power_metric": result["metric"],
        "power_comparison": result["comparison"],
        "favorable_direction": result["favorable_direction"],
        "achieved_power": achieved_value,
        "desired_power": desired,
        "minimum_detectable_effect": result.get("minimum_detectable_effect"),
        "required_prompts_per_family": result.get("required_prompts_per_family"),
        "calibration_status": result["calibration_status"],
        "calibration_problem_families": problem_families,
        "calibration_problem_family_count": len(problem_families),
        "calibration_error_row_count": error_rows,
    }
    write_json(CONFIG_PATH, config)
    set_run_state("SUPERSEDED", reason="dev design recorded into a new confirmatory config revision")
    return config["confirmatory_design"]
