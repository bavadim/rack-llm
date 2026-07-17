from __future__ import annotations

import json
from pathlib import Path

from .common import ARTIFACTS, assert_frozen, issue, load_config, write_json
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
        ["calibration", "dev", "test_generated", "test_official"],
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
        model_name, ["dev", "test_generated", "test_official"], main_stream=True
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
    pwsg = generate_pwsg(model_name, level, instances)
    pwsg_labels = ARTIFACTS / "labels" / f"{model_name}_noise_{int(level*100):02d}_pwsg.jsonl"
    evaluate_generations(instances, pwsg, pwsg_labels)
    generation_report(
        model_name, level, proposal_pool, proposal_scores,
        proposal_labels, pwsg, pwsg_labels,
    )


def run_stage(stage: str, _check_preflight: bool = True) -> None:
    assert_frozen()
    if _check_preflight and not preflight()["full_ok"]:
        raise RuntimeError("full experiment preflight failed")
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
        for name in ["audit", "aggregation", "generation", "noise", "replication"]:
            execute(name, lambda name=name: run_stage(name, False))
        execute("hard-engineering", lambda: run_hard(cars_core=False, engineering_baselines=True))
        write_json(ARTIFACTS / "stage_status.json", {
            "failed": failures,
            "completed": [name for name in [
                "hard-core", "audit", "aggregation", "generation", "noise",
                "replication", "hard-engineering",
            ] if name not in failures],
        })
        if failures:
            raise RuntimeError(f"experiment stages failed: {', '.join(failures)}")
    else:
        raise ValueError(stage)
