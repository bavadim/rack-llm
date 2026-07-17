from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any

import numpy as np

from .common import ARTIFACTS, DATA, EXPERIMENTS, REPO, assert_frozen, atomic_jsonl_command, issue, load_config, python_env, read_jsonl, write_json, write_jsonl
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


def _hf_baseline(method: str, rows: list[dict[str, Any]], model_name: str) -> Path:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    model_config = _model_config(model_name)
    tokenizer = AutoTokenizer.from_pretrained(model_config["hf_path"], local_files_only=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_config["hf_path"], local_files_only=True,
        torch_dtype=torch.bfloat16, device_map="cuda",
    )
    output_rows = []
    processors: dict[tuple[str, int], Any] = {}
    if method == "outlines":
        import outlines
        backend = outlines.from_transformers(model, tokenizer)
    else:
        import guidance
        backend = guidance.models.Transformers(model, tokenizer=tokenizer, echo=False)
    for row in rows:
        pattern = _regex_for_hard(row)
        for seed in load_config()["generation_seeds"]:
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
                        temperature=1.0, do_sample=True,
                    ))
                else:
                    import guidance
                    key = (pattern, int(row["max_tokens"]))
                    grammar = processors.get(key)
                    if grammar is None:
                        grammar = guidance.gen(
                            name="answer", regex=pattern,
                            max_tokens=row["max_tokens"], temperature=1.0,
                        )
                        processors[key] = grammar
                    result = backend + row["model_prompt"] + grammar
                    raw_text = str(result["answer"])
                output_rows.append({
                    "prompt_id": row["id"], "family": row["family"],
                    "split": row["split"], "seed": seed, "method": method,
                    "status": "pending-validation", "reason": None,
                    "text": raw_text, "raw_text": raw_text, "hard_valid": False,
                    "latency_ms": (time.perf_counter() - started) * 1000,
                })
            except Exception as exc:
                issue(f"hard.{method}", exc, prompt_id=row["id"], seed=seed)
                output_rows.append({
                    "prompt_id": row["id"], "family": row["family"],
                    "split": row["split"], "seed": seed, "method": method,
                    "status": "error", "text": "", "raw_text": "",
                    "hard_valid": False,
                    "latency_ms": (time.perf_counter() - started) * 1000,
                })
    by_id = {row["id"]: row for row in rows}
    pending = [row for row in output_rows if row["status"] == "pending-validation"]
    validity = hard_accepts_many([
        (by_id[row["prompt_id"]]["hard_spec"], row["raw_text"], None)
        for row in pending
    ])
    for row, valid in zip(pending, validity, strict=True):
        row["status"] = "found"
        row["reason"] = None if valid else "backend output is not a complete hard match"
        row["hard_valid"] = valid
    output = ARTIFACTS / "hard" / f"{method}.jsonl"
    write_jsonl(output, output_rows)
    del model
    torch.cuda.empty_cache()
    return output


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
        "--temperature", "1.0", "--seeds", ",".join(map(str, config["generation_seeds"])),
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
    found_items = [
        (instance_by_id[row["prompt_id"]], row.get("text", ""))
        for _method, row in raw_evaluated if row.get("status") == "found"
    ]
    gold_values = iter(official_check_many(
        found_items,
        workers=max(1, int(config.get("runtime", {}).get("evaluator_workers", 1))),
    ))
    evaluated = []
    for method, row in raw_evaluated:
        found = row.get("status") == "found"
        gold = next(gold_values) if found else False
        hard_valid = bool(row.get("hard_valid", False))
        evaluated.append({
            **row, "method": method, "gold_pass": gold,
            "outcome": "FOUND_OK" if found and gold else "FOUND_WRONG" if found else "NOT_FOUND",
            "hard_valid": hard_valid,
        })
    write_jsonl(ARTIFACTS / "hard" / "hard_sanity_evaluated.jsonl", evaluated)
    summary = []
    for method in sorted({row["method"] for row in evaluated}):
        items = [row for row in evaluated if row["method"] == method]
        summary.append({
            "method": method, "runs": len(items),
            "hard_valid_rate": (
                sum(row["hard_valid"] for row in items if row["outcome"] != "NOT_FOUND")
                / max(1, sum(row["outcome"] != "NOT_FOUND" for row in items))
            ),
            "invalid_return_rate": (
                sum(row["outcome"] != "NOT_FOUND" and not row["hard_valid"] for row in items)
                / max(1, sum(row["outcome"] != "NOT_FOUND" for row in items))
            ),
            "found": sum(row["outcome"] != "NOT_FOUND" for row in items),
            "not_found": sum(row["outcome"] == "NOT_FOUND" for row in items),
            "mean_latency_ms": float(np.mean([row["latency_ms"] for row in items])),
            "mean_content_tokens": float(np.mean([
                row.get("proposed_tokens", row.get("token_count", 0))
                for row in items
            ])),
            "mean_model_draws": float(np.mean([
                row.get("model_draws", 0)
                for row in items
            ])),
            "mean_trie_size": float(np.mean([
                row.get("trie_nodes", 0) for row in items
            ])),
            "mean_rejected_prefixes": float(np.mean([
                row.get("rejected_attempts", 0) for row in items
            ])),
        })
    write_jsonl(ARTIFACTS / "hard" / "hard_sanity_summary.jsonl", summary)
    cars_rows = [row for row in evaluated if row["method"] == "cars"]
    if cars_core and (
        len(cars_rows) != len(hard_rows) * len(config["generation_seeds"])
        or any(
            row["outcome"] != "NOT_FOUND" and not row["hard_valid"]
            for row in cars_rows
        )
    ):
        raise RuntimeError("CARS hard-sanity core gate failed")
