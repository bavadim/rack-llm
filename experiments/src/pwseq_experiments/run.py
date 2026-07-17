from __future__ import annotations

import json
from pathlib import Path

from .common import ARTIFACTS, DATA, assert_frozen, file_hash, issue, load_config, read_jsonl, run_state, set_run_state, write_json
from .hard import analyze_synthetic, run_hard, run_synthetic
from .preflight import preflight
from .pipeline import (
    aggregation_report, all_instances, apply_noise, audit_report,
    evaluate_candidates, evaluate_generations, fit_score, generate_pool,
    generate_pwsg, generation_report, observe, score_pool,
)

_CANDIDATE_CONTEXT_CACHE: dict[str, tuple[Path, Path, Path]] = {}
_PROPOSAL_CONTEXT_CACHE: dict[str, tuple[Path, Path, Path]] = {}
_AGGREGATION_CONTEXT_CACHE: dict[tuple[str, float], tuple[Path, Path]] = {}


def _candidate_context(model_name: str) -> tuple[Path, Path, Path]:
    if model_name in _CANDIDATE_CONTEXT_CACHE:
        return _CANDIDATE_CONTEXT_CACHE[model_name]
    pool = generate_pool(
        model_name,
        ["calibration", "dev", "test", "test_official"],
        main_stream=False,
    )
    instances = ARTIFACTS / "inputs" / f"{model_name}_candidate_instances.jsonl"
    labels = ARTIFACTS / "labels" / f"{model_name}_candidate_labels.jsonl"
    evaluate_candidates(instances, pool, labels)
    result = (pool, instances, labels)
    _CANDIDATE_CONTEXT_CACHE[model_name] = result
    return result


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
    pool, _instances, labels = _candidate_context(model_name)
    rows = apply_noise(all_instances(), level)
    observations = observe(model_name, pool, rows, level)
    from .common import ARTIFACTS, write_json
    from .pipeline import technical_filter
    selected, filter_report = technical_filter(rows, observations)
    write_json(
        ARTIFACTS / "reports" / f"{model_name}_noise_{int(level*100):02d}_filter.json",
        {"selected_slots": selected, "rules": filter_report},
    )
    audit_report(model_name, level, observations, labels, selected, rows)


def run_aggregation(model_name: str = "main", level: float = 0.0) -> tuple[Path, Path]:
    key = (model_name, level)
    if key in _AGGREGATION_CONTEXT_CACHE:
        return _AGGREGATION_CONTEXT_CACHE[key]
    pool, _instances, labels = _candidate_context(model_name)
    rows = apply_noise(all_instances(), level)
    instances, scores = fit_score(model_name, pool, rows, level)
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
    evaluate_candidates(candidate_instances, candidate_pool, candidate_labels)
    instances, _scores = fit_score("main_mixed", candidate_pool, rows, 0.0)
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
    evaluate_candidates(candidate_instances, candidate_pool, candidate_labels)
    instances, _scores = fit_score("main_design", candidate_pool, rows, 0.0)
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


def run_stage(stage: str, _check_preflight: bool = True) -> None:
    assert_frozen()
    if _check_preflight and not preflight()["full_ok"]:
        raise RuntimeError("full experiment preflight failed")
    if stage == "all":
        if run_state() != "FROZEN":
            raise RuntimeError(f"run-all requires FROZEN state, got {run_state()}")
        design = load_config().get("confirmatory_design", {})
        if design.get("status") != "finalized":
            raise RuntimeError("confirmatory run requires a finalized dev-only design decision")
        if (
            design.get("frozen_test_prompts") != 600
            or design.get("test_dataset_sha256") != file_hash(DATA / "test.jsonl")
        ):
            raise RuntimeError("confirmatory design does not match the frozen test dataset")
        set_run_state("RUNNING")
    config = load_config()
    if stage == "hard":
        synthetic = run_synthetic()
        if synthetic.exists():
            summary = analyze_synthetic(synthetic)
            if not json.loads(summary.read_text(encoding="utf-8"))["success"]:
                raise RuntimeError("corrected synthetic exactness gate failed")
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
        run_generation("replication", 0.0)
        run_generation("replication", max(config["noise_levels"]))
    elif stage == "mixed":
        run_mixed()
    elif stage == "design":
        if run_state() != "FROZEN":
            raise RuntimeError(f"design requires FROZEN state, got {run_state()}")
        run_design()
    elif stage == "all":
        failures = []
        def execute(name, thunk):
            try:
                thunk()
            except Exception as exc:
                failures.append(name)
                issue(f"run-all.{name}", exc)
        def hard_core():
            summary = analyze_synthetic(run_synthetic())
            if not json.loads(summary.read_text(encoding="utf-8"))["success"]:
                raise RuntimeError("corrected synthetic exactness gate failed")
            run_hard(cars_core=True, engineering_baselines=False)
        execute("hard-core", hard_core)
        for name in ["audit", "aggregation", "generation", "noise", "replication", "mixed"]:
            execute(name, lambda name=name: run_stage(name, False))
        execute("hard-engineering", lambda: run_hard(cars_core=False, engineering_baselines=True))
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
