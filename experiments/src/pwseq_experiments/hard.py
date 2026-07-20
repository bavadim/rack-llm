from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

import numpy as np

from .common import ARTIFACTS, DATA, EXPERIMENTS, REPO, assert_frozen, atomic_jsonl_command, file_hash, issue, load_config, python_env, read_jsonl, write_json, write_jsonl
from .evaluator import official_check_many
from .hard_validation import hard_accepts_many
from .pipeline import _model_config, _run_racket_sharded, render_instances


def run_synthetic() -> Path:
    output = ARTIFACTS / "hard" / "synthetic_raw.jsonl"
    atomic_jsonl_command(
        "hard.synthetic",
        [
            "racket", str(EXPERIMENTS / "racket" / "synthetic_exactness.rkt"),
            "--output", str(output), "--samples-per-seed", "20000",
            "--seeds", "0,1,2,3,4",
        ],
        output, expected_rows=10, cwd=REPO, env=python_env(),
    )
    return output


def analyze_synthetic(path: Path) -> Path:
    rows = read_jsonl(path)
    results = []
    rng = np.random.default_rng(20260716)
    for row in rows:
        labels = sorted(row["theoretical"])
        p = np.asarray([row["theoretical"][key] for key in labels], dtype=float)
        n = int(row["samples"])
        bootstrap = rng.multinomial(n, p, size=100000) / n
        tv_boot = .5 * np.abs(bootstrap - p).sum(axis=1)
        kl_boot = np.sum(
            np.where(bootstrap > 0, bootstrap * np.log(bootstrap / p), 0.0),
            axis=1,
        )
        entry = {
            "case": row["case"], "horizon": row["horizon"],
            "seed": row["seed"], "samples": n,
        }
        for method in ["cars", "naive"]:
            empirical = np.asarray([row[f"{method}_counts"][key] / n for key in labels])
            tv = float(.5 * np.abs(empirical - p).sum())
            kl = float(np.sum(np.where(empirical > 0, empirical * np.log(empirical / p), 0.0)))
            entry[f"{method}_tv"] = tv
            entry[f"{method}_kl"] = kl
            entry[f"{method}_within_999pct"] = bool(
                tv <= np.quantile(tv_boot, .999) and kl <= np.quantile(kl_boot, .999)
            )
            entry[f"{method}_draws_per_sample"] = row[f"{method}_model_draws"] / n
        entry["cars_invalid"] = row["cars_invalid"]
        results.append(entry)
    summary = {
        "rows": results,
        "success": bool(
            results
            and all(
                row["cars_invalid"] == 0
                and row["cars_within_999pct"]
                and row["naive_within_999pct"]
                for row in results
            )
            and np.mean([row["cars_draws_per_sample"] for row in results])
            <= np.mean([row["naive_draws_per_sample"] for row in results])
        ),
    }
    output = ARTIFACTS / "hard" / "synthetic_summary.json"
    write_json(output, summary)
    if not summary["success"]:
        issue(
            "hard.synthetic_exactness",
            "corrected CARS/naive finite-distribution exactness criterion failed",
            summary=str(output),
        )
    return output


def _regex_for_hard(row: dict[str, Any]) -> str:
    hard = row["hard_spec"]
    if hard["kind"] == "literal":
        return re.escape(hard["value"])
    if hard["kind"] == "choice":
        return "(?:" + "|".join(re.escape(value) for value in hard["values"]) + ")"
    if hard["kind"] == "ere":
        return hard["pattern"]
    raise ValueError(hard["kind"])


def _baseline_error_row(
    method: str,
    row: dict[str, Any],
    seed: int,
    *,
    reason: str,
    error_type: str,
    latency_ms: float | None,
) -> dict[str, Any]:
    return {
        "prompt_id": row["id"], "family": row["family"],
        "split": row["split"], "seed": seed, "sample_index": 0,
        "method": method, "status": "backend-error", "reason": reason,
        "backend_error": True, "backend_error_type": error_type,
        "text": "", "raw_text": "", "token_ids": [], "token_count": 0,
        "hard_valid": False, "latency_ms": latency_ms,
    }


def _write_baseline_artifact(
    method: str,
    output: Path,
    rows: list[dict[str, Any]],
    *,
    expected_rows: int,
    wall_seconds: float,
) -> Path:
    write_jsonl(output, rows)
    backend_errors = sum(row.get("status") == "backend-error" for row in rows)
    status = (
        "BASELINE_FAILED" if backend_errors == expected_rows
        else "PARTIALLY_BLOCKED" if backend_errors
        else "COMPLETE"
    )
    write_json(output.with_suffix(output.suffix + ".meta.json"), {
        "run_id": ARTIFACTS.name,
        "stage": f"hard.{method}",
        "method": method,
        "rows": len(rows),
        "expected_rows": expected_rows,
        "output_sha256": file_hash(output),
        "wall_seconds": wall_seconds,
        "rows_per_second": len(rows) / wall_seconds if wall_seconds > 0.0 else 0.0,
        "benchmark_status": status,
        "inference_status": "BLOCKED" if backend_errors else "READY",
        "backend_errors": backend_errors,
    })
    return output


def _load_hf_backend(method: str, model_name: str) -> tuple[Any, Any, Any, Any]:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    model_config = _model_config(model_name)
    tokenizer = AutoTokenizer.from_pretrained(
        model_config["hf_path"], local_files_only=True
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_config["hf_path"], local_files_only=True,
        torch_dtype=torch.bfloat16, device_map="cuda",
    )
    if method == "outlines":
        import outlines
        backend = outlines.from_transformers(model, tokenizer)
    elif method == "guidance":
        import guidance
        backend = guidance.models.Transformers(
            model, tokenizer=tokenizer, echo=False
        )
    else:
        raise ValueError(f"unknown hard baseline: {method}")
    return torch, model, tokenizer, backend


def _hf_baseline(method: str, rows: list[dict[str, Any]], model_name: str) -> Path:
    output = ARTIFACTS / "hard" / f"{method}.jsonl"
    seeds = [int(seed) for seed in load_config()["generation_seeds"]]
    expected_rows = len(rows) * len(seeds)
    benchmark_started = time.perf_counter()
    torch: Any = None
    model: Any = None
    tokenizer: Any = None
    backend: Any = None
    try:
        torch, model, tokenizer, backend = _load_hf_backend(method, model_name)
    except Exception as exc:
        reason = f"backend initialization failed: {type(exc).__name__}: {exc}"
        issue(f"hard.{method}.initialize", exc, method=method)
        output_rows = [
            _baseline_error_row(
                method, row, seed, reason=reason,
                error_type=type(exc).__name__, latency_ms=None,
            )
            for row in rows for seed in seeds
        ]
        result = _write_baseline_artifact(
            method, output, output_rows, expected_rows=expected_rows,
            wall_seconds=time.perf_counter() - benchmark_started,
        )
        if model is not None:
            del model
        if torch is not None:
            torch.cuda.empty_cache()
        return result

    temperature = float(load_config()["primary_temperature"])
    output_rows = []
    processors: dict[tuple[str, int], Any] = {}
    try:
        for row in rows:
            pattern = _regex_for_hard(row)
            for seed in seeds:
                torch.manual_seed(seed)
                started = time.perf_counter()
                try:
                    if method == "outlines":
                        import outlines
                        key = (pattern, int(row["max_tokens"]))
                        generator = processors.get(key)
                        if generator is None:
                            generator = outlines.Generator(
                                backend, outlines.types.Regex(pattern)
                            )
                            processors[key] = generator
                        raw_text = str(generator(
                            row["model_prompt"], max_new_tokens=row["max_tokens"],
                            temperature=temperature, do_sample=True,
                        ))
                    else:
                        import guidance
                        key = (pattern, int(row["max_tokens"]))
                        grammar = processors.get(key)
                        if grammar is None:
                            grammar = guidance.gen(
                                name="answer", regex=pattern,
                                max_tokens=row["max_tokens"], temperature=temperature,
                            )
                            processors[key] = grammar
                        result = backend + row["model_prompt"] + grammar
                        raw_text = str(result["answer"])
                    token_ids = tokenizer.encode(raw_text, add_special_tokens=False)
                    output_rows.append({
                        "prompt_id": row["id"], "family": row["family"],
                        "split": row["split"], "seed": seed, "sample_index": 0,
                        "method": method, "status": "pending-validation",
                        "reason": None, "backend_error": False,
                        "backend_error_type": None,
                        "text": raw_text, "raw_text": raw_text,
                        "token_ids": token_ids, "token_count": len(token_ids),
                        "hard_valid": False,
                        "latency_ms": (time.perf_counter() - started) * 1000,
                    })
                except Exception as exc:
                    issue(f"hard.{method}", exc, prompt_id=row["id"], seed=seed)
                    output_rows.append(_baseline_error_row(
                        method, row, seed,
                        reason=f"backend generation failed: {type(exc).__name__}: {exc}",
                        error_type=type(exc).__name__,
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ))
        by_id = {row["id"]: row for row in rows}
        pending = [
            row for row in output_rows if row["status"] == "pending-validation"
        ]
        validity = hard_accepts_many([
            (by_id[row["prompt_id"]]["hard_spec"], row["raw_text"], None)
            for row in pending
        ])
        for row, valid in zip(pending, validity, strict=True):
            row["status"] = "found"
            row["reason"] = (
                None if valid else "backend output is not a complete hard match"
            )
            row["hard_valid"] = valid
        return _write_baseline_artifact(
            method, output, output_rows, expected_rows=expected_rows,
            wall_seconds=time.perf_counter() - benchmark_started,
        )
    finally:
        del backend
        del model
        torch.cuda.empty_cache()


def _finite_values(rows: list[dict[str, Any]], key: str) -> list[float]:
    values = []
    for row in rows:
        value = row.get(key)
        if (
            isinstance(value, (int, float)) and not isinstance(value, bool)
            and np.isfinite(value)
        ):
            values.append(float(value))
    return values


def _mean_or_none(values: list[float]) -> float | None:
    return float(np.mean(values)) if values else None


def _artifact_wall_seconds(path: Path) -> float | None:
    meta_path = path.with_suffix(path.suffix + ".meta.json")
    if not meta_path.exists():
        return None
    try:
        value = json.loads(meta_path.read_text(encoding="utf-8")).get("wall_seconds")
    except (OSError, ValueError, TypeError):
        return None
    if (
        isinstance(value, (int, float)) and not isinstance(value, bool)
        and np.isfinite(value) and value >= 0.0
    ):
        return float(value)
    return None


def _summarize_method(
    method: str,
    items: list[dict[str, Any]],
    *,
    expected_runs: int,
    wall_seconds: float | None,
) -> dict[str, Any]:
    outcomes = {
        name: sum(row["outcome"] == name for row in items)
        for name in ["FOUND_OK", "FOUND_WRONG", "NOT_FOUND", "BACKEND_ERROR"]
    }
    runs = len(items)
    returned = outcomes["FOUND_OK"] + outcomes["FOUND_WRONG"]
    backend_errors = outcomes["BACKEND_ERROR"]
    grid_complete = runs == expected_runs
    blocked = backend_errors > 0 or not grid_complete
    benchmark_status = (
        "BASELINE_FAILED"
        if method in {"guidance", "outlines"} and backend_errors == runs and runs > 0
        else "BACKEND_FAILED"
        if backend_errors == runs and runs > 0
        else "PARTIALLY_BLOCKED"
        if blocked
        else "COMPLETE"
    )
    latency = _finite_values(items, "latency_ms")
    hard_valid = sum(
        bool(row.get("hard_valid", False))
        and row["outcome"] in {"FOUND_OK", "FOUND_WRONG"}
        for row in items
    )
    invalid_returns = sum(
        row["outcome"] in {"FOUND_OK", "FOUND_WRONG"}
        and not bool(row.get("hard_valid", False))
        for row in items
    )
    completed_throughput = (
        (runs - backend_errors) / wall_seconds
        if wall_seconds is not None and wall_seconds > 0.0 else None
    )
    return {
        "method": method,
        "benchmark_status": benchmark_status,
        "inference_status": "BLOCKED" if blocked else "READY",
        "grid_complete": grid_complete,
        "runs": runs,
        "expected_runs": expected_runs,
        "found_ok": outcomes["FOUND_OK"],
        "found_wrong": outcomes["FOUND_WRONG"],
        "not_found": outcomes["NOT_FOUND"],
        "backend_errors": backend_errors,
        "found": returned,
        # This is intentionally unconditional: refusals and backend failures do
        # not disappear from the denominator.  The conditional metric is kept
        # separately for diagnosing invalid returned strings.
        "hard_valid_rate": hard_valid / expected_runs if expected_runs else None,
        "unconditional_hard_valid_rate": (
            hard_valid / expected_runs if expected_runs else None
        ),
        "conditional_hard_valid_rate": (
            hard_valid / returned if returned else None
        ),
        "invalid_return_rate": (
            invalid_returns / returned if returned else None
        ),
        # A backend hole makes the scientific rate unidentified.  Keeping this
        # null prevents a failed OSS baseline from becoming an easy CARS win.
        "solve_rate": None if blocked else outcomes["FOUND_OK"] / expected_runs,
        "descriptive_solve_rate_including_backend_errors": (
            outcomes["FOUND_OK"] / expected_runs if expected_runs else None
        ),
        "median_latency_ms": float(np.median(latency)) if latency else None,
        "p95_latency_ms": float(np.quantile(latency, .95)) if latency else None,
        "mean_latency_ms": _mean_or_none(latency),
        "wall_seconds": wall_seconds,
        "runs_per_second": completed_throughput,
        "grid_rows_per_second": (
            runs / wall_seconds
            if wall_seconds is not None and wall_seconds > 0.0 else None
        ),
        "mean_content_tokens": _mean_or_none(
            _finite_values([
                {"value": row.get("proposed_tokens", row.get("token_count"))}
                for row in items if row["outcome"] != "BACKEND_ERROR"
            ], "value")
        ),
        "mean_model_draws": _mean_or_none(_finite_values(items, "model_draws")),
        "mean_trie_size": _mean_or_none(_finite_values(items, "trie_nodes")),
        "mean_rejected_prefixes": _mean_or_none(
            _finite_values(items, "rejected_attempts")
        ),
    }


def run_hard(*, cars_core: bool = True, engineering_baselines: bool = True) -> None:
    assert_frozen()
    config = load_config()
    model = _model_config("main")
    hard_rows = render_instances(read_jsonl(DATA / "hard_sanity.jsonl"), "main")
    input_path = ARTIFACTS / "inputs" / "hard_main.jsonl"
    write_jsonl(input_path, hard_rows)
    cars = ARTIFACTS / "hard" / "cars.jsonl"
    naive = ARTIFACTS / "hard" / "naive.jsonl"
    common = [
        "--input", str(input_path), "--model", model["gguf_path"],
        "--temperature", str(config["primary_temperature"]),
        "--seeds", ",".join(map(str, config["generation_seeds"])),
        "--samples-per-seed", "1", "--max-attempts", str(config["hard_max_attempts"]),
        "--deadline-ms", str(config["hard_deadline_ms"]),
    ]
    if cars_core:
        _run_racket_sharded(
            "hard.cars", ["--mode", "candidates", "--output", str(cars), *common],
            cars, records_per_input=len(config["generation_seeds"]),
        )
    baseline_paths = []
    if engineering_baselines:
        _run_racket_sharded(
            "hard.naive", ["--mode", "naive", "--output", str(naive), *common],
            naive, records_per_input=len(config["generation_seeds"]),
        )
        for method in ["guidance", "outlines"]:
            baseline_paths.append(_hf_baseline(method, hard_rows, "main"))

    instance_by_id = {row["id"]: row for row in hard_rows}
    raw_evaluated = []
    available = [("cars", cars), ("naive_rejection", naive)] + [
        (path.stem, path) for path in baseline_paths
    ]
    for method, path in available:
        if not path.exists():
            continue
        for row in read_jsonl(path):
            raw_evaluated.append((method, row))
    found_records = [
        (instance_by_id[row["prompt_id"]], row)
        for _method, row in raw_evaluated if row.get("status") == "found"
    ]
    found_items = [(instance, row.get("text", "")) for instance, row in found_records]
    hard_values = iter(hard_accepts_many([
        (instance["hard_spec"], row.get("text", ""), row.get("token_count"))
        for instance, row in found_records
    ]))
    gold_values = iter(official_check_many(
        found_items,
        workers=max(1, int(config.get("runtime", {}).get("evaluator_workers", 1))),
    ))
    evaluated = []
    for method, row in raw_evaluated:
        status = str(row.get("status", ""))
        found = status == "found"
        backend_error = bool(row.get("backend_error", False)) or status in {
            "error", "backend-error",
        }
        gold = next(gold_values) if found else False
        hard_valid = next(hard_values) if found else False
        outcome = (
            "FOUND_OK" if found and hard_valid and gold
            else "FOUND_WRONG" if found
            else "BACKEND_ERROR" if backend_error or not status.startswith("not-found")
            else "NOT_FOUND"
        )
        evaluated.append({
            **row, "method": method,
            "gold_pass": gold if found else None,
            "backend_error": outcome == "BACKEND_ERROR",
            "outcome": outcome,
            "hard_valid": hard_valid,
        })
    expected_runs = len(hard_rows) * len(config["generation_seeds"])
    path_by_method = {method: path for method, path in available if path.exists()}
    summary = []
    for method in sorted({row["method"] for row in evaluated}):
        items = [row for row in evaluated if row["method"] == method]
        summary.append(_summarize_method(
            method, items, expected_runs=expected_runs,
            wall_seconds=_artifact_wall_seconds(path_by_method[method]),
        ))
    status_by_method = {row["method"]: row for row in summary}
    for row in evaluated:
        method_status = status_by_method[row["method"]]
        row["benchmark_status"] = method_status["benchmark_status"]
        row["inference_status"] = method_status["inference_status"]
        row["scientific_eligible"] = (
            method_status["inference_status"] == "READY"
        )
    write_jsonl(ARTIFACTS / "hard" / "hard_sanity_evaluated.jsonl", evaluated)
    write_jsonl(ARTIFACTS / "hard" / "hard_sanity_summary.jsonl", summary)
    cars_rows = [row for row in evaluated if row["method"] == "cars"]
    if cars_core and len(cars_rows) != expected_runs:
        raise RuntimeError(
            f"incomplete CARS hard-sanity grid: {len(cars_rows)}/{expected_runs}"
        )
