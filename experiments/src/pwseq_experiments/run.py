from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .common import ARTIFACTS, DATA, assert_frozen, file_hash, issue, load_config, read_jsonl, run_state, set_run_state, write_json
from .hard import analyze_synthetic, run_hard, run_synthetic
from .preflight import preflight
from .power import FAVORABLE_DIRECTION, POWER_COMPARISON, POWER_METRIC
from .pipeline import (
    aggregation_report, all_instances, apply_noise, audit_report,
    evaluate_candidates, evaluate_generations, fit_score, generate_pool,
    generate_pwsg, generation_report, observe, score_pool, temperature_policy,
)

_CANDIDATE_INPUT_CACHE: dict[str, tuple[Path, Path]] = {}
_CANDIDATE_LABEL_CACHE: dict[str, Path] = {}
_PROPOSAL_CONTEXT_CACHE: dict[str, tuple[Path, Path, Path]] = {}
_AGGREGATION_CONTEXT_CACHE: dict[tuple[str, float], tuple[Path, Path]] = {}


def _candidate_inputs(model_name: str) -> tuple[Path, Path]:
    if model_name in _CANDIDATE_INPUT_CACHE:
        return _CANDIDATE_INPUT_CACHE[model_name]
    pool = generate_pool(
        model_name,
        ["calibration", "dev", "test", "test_official"],
        main_stream=False,
    )
    instances = ARTIFACTS / "inputs" / f"{model_name}_candidate_instances.jsonl"
    result = (pool, instances)
    _CANDIDATE_INPUT_CACHE[model_name] = result
    return result


def _candidate_labels(model_name: str, pool: Path, instances: Path) -> Path:
    if model_name in _CANDIDATE_LABEL_CACHE:
        return _CANDIDATE_LABEL_CACHE[model_name]
    labels = ARTIFACTS / "labels" / f"{model_name}_candidate_labels.jsonl"
    evaluate_candidates(instances, pool, labels)
    _CANDIDATE_LABEL_CACHE[model_name] = labels
    return labels


def _proposal_context(model_name: str) -> tuple[Path, Path, Path]:
    if model_name in _PROPOSAL_CONTEXT_CACHE:
        return _PROPOSAL_CONTEXT_CACHE[model_name]
    pool = generate_pool(
        model_name, ["dev", "test", "test_official"], main_stream=True
    )
    instances = ARTIFACTS / "inputs" / f"{model_name}_main_instances.jsonl"
    labels = ARTIFACTS / "labels" / f"{model_name}_main_labels.jsonl"
    evaluate_candidates(instances, pool, labels)
    result = (pool, instances, labels)
    _PROPOSAL_CONTEXT_CACHE[model_name] = result
    return result


def run_audit(model_name: str = "main", level: float = 0.0) -> None:
    # Audit may inspect gold, so force the zero-label fit to exist first even
    # when this stage is invoked directly or before `aggregation` in run-all.
    run_aggregation(model_name, level)
    pool, candidate_instances = _candidate_inputs(model_name)
    rows = apply_noise(all_instances(), level)
    observations = observe(model_name, pool, rows, level)
    labels = _candidate_labels(model_name, pool, candidate_instances)
    audit_report(model_name, level, observations, labels, instances=rows)


def run_aggregation(model_name: str = "main", level: float = 0.0) -> tuple[Path, Path]:
    key = (model_name, level)
    if key in _AGGREGATION_CONTEXT_CACHE:
        return _AGGREGATION_CONTEXT_CACHE[key]
    pool, candidate_instances = _candidate_inputs(model_name)
    rows = apply_noise(all_instances(), level)
    # Freeze the zero-label fit before materializing any official labels.
    instances, scores = fit_score(model_name, pool, rows, level)
    labels = _candidate_labels(model_name, pool, candidate_instances)
    aggregation_report(model_name, level, scores, labels)
    result = (instances, scores)
    _AGGREGATION_CONTEXT_CACHE[key] = result
    return result


def run_generation(model_name: str = "main", level: float = 0.0) -> None:
    instances, _scores = run_aggregation(model_name, level)
    proposal_pool, _proposal_instances, proposal_labels = _proposal_context(model_name)
    proposal_scores = score_pool(model_name, level, instances, proposal_pool)
    pwsg = generate_pwsg(model_name, level, instances, proposal_pool)
    pwsg_labels = ARTIFACTS / "labels" / f"{model_name}_noise_{int(level*100):02d}_pwsg.jsonl"
    evaluate_generations(instances, pwsg, pwsg_labels)
    generation_report(
        model_name, level, proposal_pool, proposal_scores,
        proposal_labels, pwsg, pwsg_labels,
    )


def run_mixed() -> None:
    rows = read_jsonl(DATA / "mixed.jsonl")
    candidate_pool = generate_pool("main_mixed", ["mixed"], main_stream=False)
    candidate_instances = ARTIFACTS / "inputs" / "main_mixed_candidate_instances.jsonl"
    candidate_labels = ARTIFACTS / "labels" / "main_mixed_candidate_labels.jsonl"
    instances, _scores = fit_score("main_mixed", candidate_pool, rows, 0.0)
    evaluate_candidates(candidate_instances, candidate_pool, candidate_labels)
    proposal_pool = generate_pool("main_mixed", ["mixed"], main_stream=True)
    proposal_instances = ARTIFACTS / "inputs" / "main_mixed_main_instances.jsonl"
    proposal_labels = ARTIFACTS / "labels" / "main_mixed_main_labels.jsonl"
    evaluate_candidates(proposal_instances, proposal_pool, proposal_labels)
    proposal_scores = score_pool("main_mixed", 0.0, instances, proposal_pool)
    pwsg = generate_pwsg("main_mixed", 0.0, instances, proposal_pool)
    pwsg_labels = ARTIFACTS / "labels" / "main_mixed_noise_00_pwsg.jsonl"
    evaluate_generations(instances, pwsg, pwsg_labels)
    generation_report(
        "main_mixed", 0.0, proposal_pool, proposal_scores,
        proposal_labels, pwsg, pwsg_labels, instance_rows=rows,
    )


def design_candidate_protocol_report(
    rows: list[dict[str, Any]], candidates: list[dict[str, Any]],
) -> dict[str, Any]:
    """Validate the exact unlabeled calibration/dev candidate design."""
    policy = temperature_policy()
    primary = policy["primary_temperature"]

    def temperature_key(value: Any) -> float:
        return round(float(value), 12)

    expected: dict[tuple[str, float, int, int], tuple[str, str]] = {}
    row_ids = [str(row["id"]) for row in rows]
    duplicate_rows = len(row_ids) - len(set(row_ids))
    for row in rows:
        split = row["split"]
        if split == "calibration":
            protocols = [(primary, policy["primary_calibration_seeds"])]
        elif split == "dev":
            protocols = [(primary, policy["candidate_evaluation_seeds"])]
        else:
            protocols = []
        for temperature, seeds in protocols:
            for seed in seeds:
                expected[(
                    str(row["id"]), temperature_key(temperature), int(seed), 0,
                )] = (str(row["family"]), str(split))

    actual_keys: list[tuple[str, float, int, int]] = []
    metadata_errors = []
    invalid_returns = []
    candidate_ids = []
    for candidate in candidates:
        candidate_id = str(candidate.get("candidate_id", ""))
        candidate_ids.append(candidate_id)
        if not candidate_id:
            metadata_errors.append({"candidate_id": "", "error": "missing candidate_id"})
        try:
            key = (
                str(candidate["prompt_id"]), temperature_key(candidate["temperature"]),
                int(candidate["seed"]), int(candidate["sample_index"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            metadata_errors.append({"candidate_id": candidate_id, "error": str(exc)})
            continue
        actual_keys.append(key)
        expected_metadata = expected.get(key)
        actual_metadata = (
            str(candidate.get("family")), str(candidate.get("split")),
        )
        if expected_metadata is not None and actual_metadata != expected_metadata:
            metadata_errors.append({
                "candidate_id": candidate_id, "key": list(key),
                "expected": list(expected_metadata), "actual": list(actual_metadata),
            })
        if candidate.get("status") != "found" or candidate.get("hard_valid") is not True:
            invalid_returns.append({
                "candidate_id": candidate_id, "key": list(key),
                "status": candidate.get("status"),
                "hard_valid": candidate.get("hard_valid"),
            })
    actual_counts = Counter(actual_keys)
    actual_set = set(actual_keys)
    expected_set = set(expected)
    missing = sorted(expected_set - actual_set)
    extra = sorted(actual_set - expected_set)
    duplicate_keys = sum(count - 1 for count in actual_counts.values())
    duplicate_candidate_ids = len(candidate_ids) - len(set(candidate_ids))
    passed = not any([
        duplicate_rows, missing, extra, duplicate_keys, duplicate_candidate_ids,
        metadata_errors, invalid_returns,
    ])
    return {
        "protocol": "paper-v6-design-candidates",
        "expected_candidates": len(expected), "actual_candidates": len(candidates),
        "duplicate_instance_ids": duplicate_rows,
        "missing": len(missing), "extra": len(extra),
        "duplicate_candidate_keys": duplicate_keys,
        "duplicate_candidate_ids": duplicate_candidate_ids,
        "metadata_errors": len(metadata_errors),
        "invalid_returns": len(invalid_returns),
        "missing_examples": [list(value) for value in missing[:5]],
        "extra_examples": [list(value) for value in extra[:5]],
        "metadata_error_examples": metadata_errors[:5],
        "invalid_return_examples": invalid_returns[:5],
        "passed": passed,
    }


def gold_class_support_report(
    rows: list[dict[str, Any]], candidates: list[dict[str, Any]],
    label_rows: list[dict[str, Any]], *, minimum_per_class: int = 50,
) -> dict[str, Any]:
    """Summarize primary-temperature calibration support without pooling seeds."""
    primary = temperature_policy()["primary_temperature"]
    calibration_prompts = {
        row["id"]: row["family"] for row in rows if row["split"] == "calibration"
    }
    label_ids = [str(row["candidate_id"]) for row in label_rows]
    labels = {str(row["candidate_id"]): bool(row["gold_pass"]) for row in label_rows}
    duplicate_labels = len(label_ids) - len(set(label_ids))
    values: dict[str, list[bool]] = defaultdict(list)
    missing_labels = []
    for candidate in candidates:
        prompt_id = candidate.get("prompt_id")
        if (
            candidate.get("split") != "calibration"
            or prompt_id not in calibration_prompts
            or abs(float(candidate.get("temperature", primary)) - primary) >= 1e-12
        ):
            continue
        candidate_id = str(candidate.get("candidate_id", ""))
        if candidate_id not in labels:
            missing_labels.append(candidate_id)
            continue
        values[calibration_prompts[prompt_id]].append(labels[candidate_id])
    families = []
    for family in sorted(set(calibration_prompts.values())):
        family_values = values.get(family, [])
        valid = sum(family_values)
        invalid = len(family_values) - valid
        families.append({
            "family": family, "candidates": len(family_values),
            "gold_valid": valid, "gold_invalid": invalid,
            "passed": valid >= minimum_per_class and invalid >= minimum_per_class,
        })
    return {
        "source_split": "calibration", "temperature": primary,
        "minimum_per_class": minimum_per_class,
        "duplicate_labels": duplicate_labels,
        "missing_labels": len(missing_labels),
        "missing_label_examples": missing_labels[:5],
        "families": families,
        "passed": (
            bool(families) and not duplicate_labels and not missing_labels
            and all(row["passed"] for row in families)
        ),
    }


def run_design() -> None:
    """Generate and label calibration/dev only; never materialize a test candidate."""
    rows = [
        row for split in ["calibration", "dev"]
        for row in read_jsonl(DATA / f"{split}.jsonl")
    ]
    candidate_pool = generate_pool(
        "main_design", ["calibration", "dev"], main_stream=False
    )
    candidate_instances = ARTIFACTS / "inputs" / "main_design_candidate_instances.jsonl"
    candidate_labels = ARTIFACTS / "labels" / "main_design_candidate_labels.jsonl"
    candidates = read_jsonl(candidate_pool)
    candidate_protocol = design_candidate_protocol_report(rows, candidates)
    write_json(
        ARTIFACTS / "reports" / "main_design_candidate_protocol.json",
        candidate_protocol,
    )
    if not candidate_protocol["passed"]:
        raise RuntimeError(f"design candidate protocol failed: {candidate_protocol}")
    observations = observe("main_design", candidate_pool, rows, 0.0)
    # Fit and persist every zero-label calibration before the official
    # evaluator is invoked.  This executable ordering prevents gold outcomes
    # from influencing either the schema or the fit.
    instances, _scores = fit_score(
        "main_design", candidate_pool, rows, 0.0,
        observations_path=observations,
    )
    evaluate_candidates(candidate_instances, candidate_pool, candidate_labels)
    support = gold_class_support_report(
        rows, candidates, read_jsonl(candidate_labels), minimum_per_class=50,
    )
    write_json(ARTIFACTS / "reports" / "main_design_class_support.json", support)
    proposal_pool = generate_pool("main_design", ["dev"], main_stream=True)
    proposal_instances = ARTIFACTS / "inputs" / "main_design_main_instances.jsonl"
    proposal_labels = ARTIFACTS / "labels" / "main_design_main_labels.jsonl"
    evaluate_candidates(proposal_instances, proposal_pool, proposal_labels)
    proposal_scores = score_pool("main_design", 0.0, instances, proposal_pool)
    pwsg = generate_pwsg("main_design", 0.0, instances, proposal_pool)
    pwsg_labels = ARTIFACTS / "labels" / "main_design_noise_00_pwsg.jsonl"
    evaluate_generations(instances, pwsg, pwsg_labels)
    generation_report(
        "main_design", 0.0, proposal_pool, proposal_scores,
        proposal_labels, pwsg, pwsg_labels, instance_rows=rows,
        evaluation_splits=("dev",),
    )


def require_confirmatory_design() -> dict[str, Any]:
    """Block every stage that can materialize or evaluate a test candidate."""
    design = load_config().get("confirmatory_design", {})
    if design.get("status") != "finalized":
        raise RuntimeError(
            "test-reading stage requires a finalized dev-only design decision"
        )
    test_rows = read_jsonl(DATA / "test.jsonl")
    manifest_path = DATA / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    families = sorted(map(str, manifest.get("families", [])))
    counts = Counter(str(row["family"]) for row in test_rows)
    family_sizes = set(counts.values())
    problem_families = design.get("calibration_problem_families")
    if (
        not families
        or set(counts) != set(families)
        or len(family_sizes) != 1
        or design.get("power_status") not in {"ADEQUATE", "UNDERPOWERED"}
        or design.get("power_metric") != POWER_METRIC
        or design.get("power_comparison") != POWER_COMPARISON
        or design.get("favorable_direction") != FAVORABLE_DIRECTION
        or design.get("calibration_status") not in {"OK", "DEGRADED"}
        or not isinstance(problem_families, list)
        or problem_families != sorted(set(map(str, problem_families)))
        or not set(problem_families) <= set(families)
        or design.get("calibration_problem_family_count") != len(problem_families)
        or (design.get("calibration_status") == "OK") != (not problem_families)
        or design.get("frozen_test_prompts") != len(test_rows)
        or design.get("frozen_test_prompts_per_family") != next(iter(family_sizes), None)
        or design.get("frozen_test_families") != families
        or design.get("dataset_revision") != manifest.get("experiment_revision")
        or design.get("dataset_manifest_sha256") != file_hash(manifest_path)
        or design.get("test_dataset_sha256") != file_hash(DATA / "test.jsonl")
    ):
        raise RuntimeError("confirmatory design does not match the frozen test dataset")
    return design


def run_stage(stage: str, _check_preflight: bool = True) -> None:
    assert_frozen()
    if _check_preflight and not preflight()["full_ok"]:
        raise RuntimeError("full experiment preflight failed")
    if stage in {
        "audit", "aggregation", "generation", "noise", "replication", "mixed", "all",
    }:
        require_confirmatory_design()
    if stage == "all":
        if run_state() != "FROZEN":
            raise RuntimeError(f"run-all requires FROZEN state, got {run_state()}")
        set_run_state("RUNNING")
    config = load_config()
    if stage == "hard":
        synthetic = run_synthetic()
        if synthetic.exists():
            analyze_synthetic(synthetic)
        run_hard()
    elif stage == "audit":
        run_audit("main", 0.0)
        run_audit("replication", 0.0)
    elif stage == "aggregation":
        run_aggregation("main", 0.0)
        run_aggregation("replication", 0.0)
    elif stage == "generation":
        run_generation("main", 0.0)
    elif stage == "noise":
        for level in config["noise_levels"]:
            if float(level) == 0.0:
                continue
            run_audit("main", level)
            run_generation("main", level)
    elif stage == "replication":
        run_audit("replication", max(config["noise_levels"]))
        run_generation("replication", 0.0)
        run_generation("replication", max(config["noise_levels"]))
    elif stage == "mixed":
        run_mixed()
    elif stage == "design":
        if run_state() != "FROZEN":
            raise RuntimeError(f"design requires FROZEN state, got {run_state()}")
        set_run_state("DESIGN_RUNNING")
        try:
            run_design()
        except BaseException as exc:
            set_run_state(
                "FAILED", failed=["design"],
                reason=f"{type(exc).__name__}: {exc}",
            )
            raise
        set_run_state("DESIGN_COMPLETE")
    elif stage == "all":
        failures = []
        def execute(name, thunk):
            try:
                thunk()
            except Exception as exc:
                failures.append(name)
                issue(f"run-all.{name}", exc)
        def hard_core():
            analyze_synthetic(run_synthetic())
            run_hard(cars_core=True, engineering_baselines=False)
        execute("hard-core", hard_core)
        # Fail or record incompatible engineering backends before committing
        # several days of GPU time to the soft/weak grid.
        execute("hard-engineering", lambda: run_hard(
            cars_core=False, engineering_baselines=True,
        ))
        for name in ["audit", "aggregation", "generation", "noise", "replication", "mixed"]:
            execute(name, lambda name=name: run_stage(name, False))
        write_json(ARTIFACTS / "stage_status.json", {
            "failed": failures,
            "completed": [name for name in [
                "hard-core", "audit", "aggregation", "generation", "noise",
                "replication", "hard-engineering",
                "mixed",
            ] if name not in failures],
        })
        if failures:
            set_run_state("FAILED", failed=failures)
            raise RuntimeError(f"experiment stages failed: {', '.join(failures)}")
        set_run_state("RUN_COMPLETE")
    else:
        raise ValueError(stage)
