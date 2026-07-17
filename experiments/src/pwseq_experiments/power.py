from __future__ import annotations

import math
from collections import defaultdict

import numpy as np
from scipy.stats import norm

from .common import (
    ARTIFACTS, CONFIG_PATH, DATA, assert_frozen, file_hash, load_config,
    read_jsonl, run_state, set_run_state, stable_hash, write_json,
)


def power_analysis() -> dict:
    """Dev-only paired design calculation; never reads a test label."""
    assert_frozen()
    config = load_config()
    raw = ARTIFACTS / "results" / "main_design_noise_00_generation_raw.jsonl"
    thresholds = ARTIFACTS / "thresholds" / "main_design_noise_00.jsonl"
    if not raw.exists() or not thresholds.exists():
        raise RuntimeError("power analysis requires completed dev generation and thresholds")
    tau = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(thresholds)
    }
    by_method_prompt: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for row in read_jsonl(raw):
        if row["split"] == "dev" and int(row["budget"]) == 8 and row["method"] in {
            "exact_pwsg", "posterior_best_of_b",
        }:
            by_method_prompt[row["method"]][row["prompt_id"]].append(row)
    expected = set(map(int, config["generation_seeds"]))
    differences: dict[str, list[float]] = defaultdict(list)
    for prompt, ours in by_method_prompt["exact_pwsg"].items():
        baseline = by_method_prompt["posterior_best_of_b"].get(prompt)
        if baseline is None:
            raise RuntimeError(f"missing paired dev prompt: {prompt}")
        def solve(values: list[dict], method: str) -> float:
            if {int(row["seed"]) for row in values} != expected:
                raise RuntimeError(f"invalid dev seed cohort: {method}/{prompt}")
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
        family = ours[0]["family"]
        differences[family].append(solve(ours, "exact_pwsg") - solve(baseline, "posterior_best_of_b"))
    target = float(config["power_target_effect"])
    alpha = float(config["power_alpha"])
    desired = float(config["power_target"])
    rows = []
    selected = None
    for prompts_per_family in range(25, int(config["test_per_family_cap"]) + 1):
        variance = sum(
            float(np.var(values, ddof=1)) / prompts_per_family
            for values in differences.values() if len(values) > 1
        ) / max(1, len(differences)) ** 2
        standard_error = math.sqrt(variance)
        power = float(norm.cdf(target / standard_error - norm.ppf(1 - alpha / 2))) if standard_error else 1.0
        rows.append({"prompts_per_family": prompts_per_family, "standard_error": standard_error, "power": power})
        if selected is None and power >= desired:
            selected = prompts_per_family
    result = {
        "source_split": "dev", "gold_test_labels_read": False,
        "comparison": "exact_pwsg-minus-posterior_best_of_b",
        "budget": 8, "target_effect": target, "alpha": alpha,
        "desired_power": desired,
        "selected_prompts_per_family": selected or int(config["test_per_family_cap"]),
        "underpowered": selected is None, "grid": rows,
    }
    write_json(ARTIFACTS / "design" / "power_mde.json", result)
    return result


def finalize_design() -> dict:
    """Persist a dev-only sample-size decision, then regenerate Codex-authored tests."""
    assert_frozen()
    if run_state() != "FROZEN":
        raise RuntimeError(f"finalize-design requires FROZEN state, got {run_state()}")
    path = ARTIFACTS / "design" / "power_mde.json"
    if not path.is_file():
        raise RuntimeError("run the dev-only power analysis first")
    result = __import__("json").loads(path.read_text(encoding="utf-8"))
    if result.get("gold_test_labels_read") is not False:
        raise RuntimeError("design artifact does not prove test-label blindness")
    config = load_config()
    selected = int(result["selected_prompts_per_family"])
    if not 25 <= selected <= int(config["test_per_family_cap"]):
        raise RuntimeError(f"invalid selected test size: {selected}")
    config["test_per_family"] = selected
    config["confirmatory_design"] = {
        "status": "finalized",
        "source_run_id": ARTIFACTS.name,
        "source_split": "dev",
        "gold_test_labels_read": False,
        "power_artifact_sha256": file_hash(path),
        "decision_sha256": stable_hash(result),
        "selected_prompts_per_family": selected,
    }
    write_json(CONFIG_PATH, config)
    from .prepare import prepare_data
    manifest = prepare_data()
    set_run_state("SUPERSEDED", reason="design finalized into a new confirmatory input revision")
    return {"config": config["confirmatory_design"], "dataset": manifest["counts"]}
