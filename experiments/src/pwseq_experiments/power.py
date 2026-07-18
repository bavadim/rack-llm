from __future__ import annotations

import math
from collections import Counter, defaultdict

import numpy as np
from scipy.stats import norm

from .common import (
    ARTIFACTS, CONFIG_PATH, DATA, assert_frozen, file_hash, load_config,
    read_jsonl, run_state, set_run_state, stable_hash, write_json,
)


def power_analysis() -> dict:
    """Dev-only paired design calculation; never reads a test label."""
    assert_frozen()
    if run_state() != "DESIGN_COMPLETE":
        raise RuntimeError(f"power analysis requires DESIGN_COMPLETE state, got {run_state()}")
    config = load_config()
    raw = ARTIFACTS / "results" / "main_design_noise_00_generation_raw.jsonl"
    thresholds = ARTIFACTS / "thresholds" / "main_design_noise_00.jsonl"
    if not raw.exists() or not thresholds.exists():
        raise RuntimeError("power analysis requires completed dev generation and thresholds")
    tau = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(thresholds)
    }
    for method in ("exact_pwsg", "posterior_best_of_b"):
        decision = tau.get((method, 8))
        if decision is None or decision.get("source_split") != "dev":
            raise RuntimeError(f"missing dev-only threshold for {method}/8")
    by_method_prompt: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for row in read_jsonl(raw):
        if row["split"] == "dev" and int(row["budget"]) == 8 and row["method"] in {
            "exact_pwsg", "posterior_best_of_b",
        }:
            by_method_prompt[row["method"]][row["prompt_id"]].append(row)
    dev_rows = read_jsonl(DATA / "dev.jsonl")
    expected_prompts = {row["id"]: row["family"] for row in dev_rows}
    if len(expected_prompts) != len(dev_rows):
        raise RuntimeError("dev dataset contains duplicate prompt ids")
    expected = set(map(int, config["generation_seeds"]))
    for method in ("exact_pwsg", "posterior_best_of_b"):
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
            decision = tau[(method, 8)]
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
    alpha = float(config["power_alpha"])
    desired = float(config["power_target"])
    test_rows = read_jsonl(DATA / "test.jsonl")
    test_counts = Counter(row["family"] for row in test_rows)
    if (
        len(test_rows) != 600 or set(test_counts) != set(differences)
        or set(test_counts.values()) != {50}
    ):
        raise RuntimeError("power analysis requires the frozen 600-row test dataset")
    prompts_per_family = 50
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
    result = {
        "source_split": "dev", "gold_test_labels_read": False,
        "comparison": "exact_pwsg-minus-posterior_best_of_b",
        "budget": 8, "target_effect": target, "alpha": alpha,
        "desired_power": desired, "test_size_is_fixed": True,
        "prompts_per_family": prompts_per_family,
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
    result = __import__("json").loads(path.read_text(encoding="utf-8"))
    if result.get("gold_test_labels_read") is not False:
        raise RuntimeError("design artifact does not prove test-label blindness")
    config = load_config()
    config["confirmatory_design"] = {
        "status": "finalized",
        "source_run_id": ARTIFACTS.name,
        "source_split": "dev",
        "gold_test_labels_read": False,
        "power_artifact_sha256": file_hash(path),
        "decision_sha256": stable_hash(result),
        "frozen_test_prompts": 600,
        "test_dataset_sha256": file_hash(DATA / "test.jsonl"),
    }
    write_json(CONFIG_PATH, config)
    set_run_state("SUPERSEDED", reason="dev design recorded into a new confirmatory config revision")
    return config["confirmatory_design"]
