#!/usr/bin/env python3
"""Run the Experiment 012 real soft benchmark over audited real candidates."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import shutil
import statistics
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import regex

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from experiments.ifbench.outcomes import Candidate, Outcome
from experiments.ifbench.soft_methods import policy_label, threshold_for_policy


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

AUDITED_RULES = ROOT_DATA_DIR / "012_soft_ifbench_rules_audited.jsonl"
CANDIDATE_POOL = ROOT_DATA_DIR / "012_soft_candidate_pool.jsonl"
SMOKE_RAW = RESULTS_DIR / "019_ours_soft_smoke_raw.jsonl"
OURS_GENERATION_RAW = RESULTS_DIR / "012_ours_soft_generation_raw.jsonl"
RACKET_OURS_BATCH = EXPERIMENT_DIR / "code" / "racket_ours_soft_batch.rkt"
VENDOR_DIR = REPO_ROOT / "experiments" / "004_hard_guide_agreement" / "vendor" / "ifbench"

RAW_NAME = "012_soft_real_raw.jsonl"
SUMMARY_NAME = "012_soft_real_summary.csv"
RISK_NAME = "012_soft_real_risk_coverage.csv"
MISSING_NAME = "012_missing_runs.json"

METHOD_NAMES = [
    "vanilla",
    "best_of_n_lm",
    "weak_posthoc_rerank",
    "weak_rejection",
    "ours_soft_decoding",
    "ours_hybrid_decoding",
    "oracle_verifier_selection",
]
POOL_METHODS = {"vanilla", "best_of_n_lm", "weak_posthoc_rerank", "weak_rejection", "oracle_verifier_selection"}
OURS_METHODS = {"ours_soft_decoding", "ours_hybrid_decoding"}
NOISE_LEVELS = ["clean", "noisy_20", "noisy_40"]
BUDGETS = [1, 4, 8, 16]
POLICIES = ["always", "risk_target:0.05"]
MIN_AUDITED_ROWS = 150
REGEX_TIMEOUT_SECONDS = 0.005
MAX_OURS_SAMPLES = 16
OURS_TOP_K = 128
OURS_PROVIDER_MODE = "exact-full-vocab"
OURS_MAX_TOKENS = 96
OURS_DEADLINE_MS = 30000


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def split_for_key(key: str) -> str:
    digest = int(hashlib.sha256(key.encode("utf-8")).hexdigest()[:8], 16)
    return "dev" if digest % 10 < 3 else "test"


def pool_sort_key(row: dict[str, Any]) -> tuple[int, int, int, str]:
    source_rank = {
        "real_qwen_unconstrained": 0,
        "real_qwen_strict_chat_no_think": 1,
        "real_qwen_strict_final": 2,
    }.get(row["pool_source"], 99)
    return (source_rank, int(row.get("candidate_index", 0)), int(row.get("seed", 0)), row.get("candidate_id", ""))


def to_candidate(pool_row: dict[str, Any], local_index: int) -> Candidate:
    return Candidate(
        example_id=pool_row["key"],
        candidate_id=local_index,
        text=pool_row["text"],
        lm_logprob=float(pool_row.get("lm_logprob") or 0.0),
        metadata={"official_verifier": bool(pool_row["official_verifier"])},
    )


def policy_object(policy: str, dev_scores: list[tuple[float, bool]]):
    if policy == "always":
        return "always"
    if policy == "risk_target:0.05":
        return ("risk_target", 0.05, dev_scores)
    raise ValueError(policy)


def rule_set_hash(row: dict[str, Any], noise: str) -> str:
    payload = json.dumps(row["rule_sets"][noise], ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def load_registry():
    sys.path.insert(0, str(VENDOR_DIR))
    import importlib

    return importlib.import_module("instructions_registry")


def non_null(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in kwargs.items() if value is not None}


def official_check(row: dict[str, Any], text: str, registry_module: Any) -> bool:
    if not text or not text.strip():
        return False
    results = []
    for index, instruction_id in enumerate(row["instruction_id_list"]):
        instruction_cls = registry_module.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)
        kwargs = non_null(row["kwargs"][index])
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=row["prompt"])
        results.append(bool(instruction.check_following(text)))
    return all(results)


def weak_score_fast(text: str, rules: list[dict[str, Any]]) -> float:
    score = 0.0
    for rule in rules:
        if rule_fires_fast(rule, text):
            if rule["kind"] == "ban":
                return float("-inf")
            score += float(rule["weight"])
    return score


def rule_fires_fast(rule: dict[str, Any], text: str) -> bool:
    pattern = rule["pattern"]
    try:
        if rule["pattern_type"] == "literal":
            return pattern in text
        if rule["pattern_type"] == "regex":
            compiled = regex.compile(pattern, regex.MULTILINE | regex.DOTALL)
            return compiled.search(text, timeout=REGEX_TIMEOUT_SECONDS) is not None
    except (regex.error, TimeoutError):
        return False
    return False


def dev_scores_for(rows: list[dict[str, Any]], pool_by_key: dict[str, list[dict[str, Any]]], noise: str, score_for) -> list[tuple[float, bool]]:
    scores = []
    for row in rows:
        if split_for_key(row["key"]) != "dev":
            continue
        for pool_row in pool_by_key[row["key"]]:
            scores.append((score_for(noise, row, pool_row), bool(pool_row["official_verifier"])))
    return scores


def official_for(indexed_pool_rows: list[tuple[int, dict[str, Any]]]):
    by_index = {local_index: bool(row["official_verifier"]) for local_index, row in indexed_pool_rows}
    by_text = {row["text"]: bool(row["official_verifier"]) for _local_index, row in indexed_pool_rows}

    def check(text: str) -> bool:
        return by_text.get(text, False)

    check.by_index = by_index  # type: ignore[attr-defined]
    return check


def outcome_for(result, indexed_pool_rows: list[tuple[int, dict[str, Any]]]) -> Outcome:
    if not result.returned or result.candidate_id is None:
        return Outcome.NOT_FOUND
    by_index = {local_index: row for local_index, row in indexed_pool_rows}
    row = by_index.get(int(result.candidate_id))
    if row is None or row["text"] != result.text:
        return Outcome.FOUND_WRONG
    return Outcome.FOUND_OK if row["official_verifier"] else Outcome.FOUND_WRONG


def outcome_for_selected(result: dict[str, Any], indexed_pool_rows: list[tuple[int, dict[str, Any]]]) -> Outcome:
    if not result["returned"] or result["candidate_id"] is None:
        return Outcome.NOT_FOUND
    by_index = {local_index: row for local_index, row in indexed_pool_rows}
    row = by_index.get(int(result["candidate_id"]))
    if row is None or row["text"] != result["text"]:
        return Outcome.FOUND_WRONG
    return Outcome.FOUND_OK if row["official_verifier"] else Outcome.FOUND_WRONG


def first_gold_rank(indexed_pool_rows: list[tuple[int, dict[str, Any]]]) -> int | None:
    for rank, (_local_index, row) in enumerate(indexed_pool_rows, start=1):
        if row["official_verifier"]:
            return rank
    return None


def selected_rows(pool_rows: list[dict[str, Any]], n: int) -> list[tuple[int, dict[str, Any]]]:
    return list(enumerate(pool_rows[:n]))


def selected_payload(method: str, item: tuple[int, dict[str, Any]] | None, weak: float | None, return_policy) -> dict[str, Any]:
    if item is None:
        return {
            "candidate_id": None,
            "text": None,
            "lm_logprob": None,
            "weak_score": weak,
            "total_score": None,
            "returned": False,
            "return_policy": policy_label(return_policy),
            "hybrid_fallback": False,
        }
    local_index, row = item
    lm_logprob = float(row.get("lm_logprob") or 0.0)
    total_score = lm_logprob + (weak or 0.0)
    return {
        "candidate_id": local_index,
        "text": row["text"],
        "lm_logprob": lm_logprob,
        "weak_score": weak,
        "total_score": total_score,
        "returned": True,
        "return_policy": policy_label(return_policy),
        "hybrid_fallback": False,
    }


def maybe_selected_payload(method: str, item: tuple[int, dict[str, Any]] | None, weak: float | None, return_policy) -> dict[str, Any]:
    if item is None:
        return selected_payload(method, None, weak, return_policy)
    if weak is not None and weak < threshold_for_policy(return_policy):
        return selected_payload(method, None, weak, return_policy)
    return selected_payload(method, item, weak, return_policy)


def select_pool_method(method: str, indexed: list[tuple[int, dict[str, Any]]], row: dict[str, Any], noise: str, return_policy, score_for) -> dict[str, Any]:
    if method == "vanilla":
        return maybe_selected_payload(method, indexed[0] if indexed else None, None, return_policy)
    if method == "best_of_n_lm":
        item = max(indexed, key=lambda pair: float(pair[1].get("lm_logprob") or 0.0), default=None)
        return maybe_selected_payload(method, item, None, return_policy)
    if method == "weak_posthoc_rerank":
        scored = [(score_for(noise, row, pool_row), (local_index, pool_row)) for local_index, pool_row in indexed]
        if not scored:
            return selected_payload(method, None, None, return_policy)
        score, item = max(scored, key=lambda pair: (pair[0], float(pair[1][1].get("lm_logprob") or 0.0)))
        return maybe_selected_payload(method, item, score, return_policy)
    if method == "weak_rejection":
        threshold = threshold_for_policy(return_policy)
        for local_index, pool_row in indexed:
            score = score_for(noise, row, pool_row)
            if score >= threshold:
                return selected_payload(method, (local_index, pool_row), score, return_policy)
        return selected_payload(method, None, None, return_policy)
    if method == "oracle_verifier_selection":
        for item in indexed:
            if item[1]["official_verifier"]:
                return selected_payload(method, item, None, return_policy)
        return selected_payload(method, None, None, return_policy)
    raise ValueError(f"unsupported pool method: {method}")


def ensure_ours_generation_samples(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    expected = len(rows) * len(NOISE_LEVELS) * len(OURS_METHODS) * MAX_OURS_SAMPLES
    if OURS_GENERATION_RAW.exists():
        existing = read_jsonl(OURS_GENERATION_RAW)
        if len(existing) == expected and ours_generation_artifact_is_current(existing):
            return existing
    subprocess.run(
        [
            "racket",
            str(RACKET_OURS_BATCH),
            "--rules",
            str(AUDITED_RULES),
            "--output",
            str(OURS_GENERATION_RAW),
            "--samples",
            str(MAX_OURS_SAMPLES),
            "--provider-mode",
            OURS_PROVIDER_MODE,
            "--max-tokens",
            str(OURS_MAX_TOKENS),
            "--deadline-ms",
            str(OURS_DEADLINE_MS),
        ],
        cwd=REPO_ROOT,
        check=True,
    )
    samples = read_jsonl(OURS_GENERATION_RAW)
    if len(samples) != expected:
        raise SystemExit(f"ours generation rows {len(samples)} != expected {expected}")
    return samples


def ours_generation_artifact_is_current(rows: list[dict[str, Any]]) -> bool:
    if not rows:
        return False
    return all(
        row.get("provider_mode") == OURS_PROVIDER_MODE
        and row.get("approximation") == "none"
        and row.get("generation_backend") == "racket_generate_hf_sidecar_full_vocab"
        for row in rows
    )


def enriched_ours_samples(rows: list[dict[str, Any]]) -> dict[tuple[str, str, str], list[dict[str, Any]]]:
    registry = load_registry()
    rows_by_key = {row["key"]: row for row in rows}
    official_cache: dict[tuple[str, str], bool] = {}
    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for sample in ensure_ours_generation_samples(rows):
        row = rows_by_key[sample["key"]]
        text = sample.get("text") or ""
        official_key = (sample["key"], text)
        if official_key not in official_cache:
            official_cache[official_key] = official_check(row, text, registry)
        enriched = {
            **sample,
            "split": split_for_key(sample["key"]),
            "official_verifier": official_cache[official_key],
            "rule_set_hash": rule_set_hash(row, sample["noise"]),
        }
        grouped[(sample["method"], sample["noise"], sample["key"])].append(enriched)
    for samples in grouped.values():
        samples.sort(key=lambda item: int(item["sample_index"]))
    return grouped


def ours_dev_scores(
    rows: list[dict[str, Any]],
    ours_by_key: dict[tuple[str, str, str], list[dict[str, Any]]],
    method: str,
    noise: str,
    n: int,
) -> list[tuple[float, bool]]:
    scores = []
    for row in rows:
        if split_for_key(row["key"]) != "dev":
            continue
        for sample in ours_by_key[(method, noise, row["key"])][:n]:
            if sample.get("status") == "found" and sample.get("guide_score") is not None:
                scores.append((float(sample["guide_score"]), bool(sample["official_verifier"])))
    return scores


def select_ours_method(
    method: str,
    samples: list[dict[str, Any]],
    n: int,
    return_policy,
) -> dict[str, Any]:
    considered = samples[:n]
    viable = [
        sample
        for sample in considered
        if sample.get("status") == "found"
        and sample.get("text")
        and sample.get("total_score") is not None
        and sample.get("guide_score") is not None
    ]
    best = max(viable, key=lambda item: float(item["total_score"]), default=None)
    threshold = threshold_for_policy(return_policy)
    returned = best is not None and float(best["guide_score"]) >= threshold
    generation_latency = sum(float(sample.get("latency_ms") or 0.0) for sample in considered)
    generation_tokens = sum(int(sample.get("generated_tokens") or 0) for sample in considered)
    duplicate_count = n - len({sample.get("text") or "" for sample in considered})
    oracle_samples = [sample for sample in considered if sample.get("status") == "found"]
    first_gold = next(
        (int(sample["sample_index"]) + 1 for sample in oracle_samples if sample["official_verifier"]),
        None,
    )
    if not returned:
        return {
            "candidate_id": None,
            "text": None,
            "lm_logprob": None,
            "weak_score": best.get("guide_score") if best else None,
            "guide_score": best.get("guide_score") if best else None,
            "total_score": None,
            "returned": False,
            "return_policy": policy_label(return_policy),
            "hybrid_fallback": method == "ours_hybrid_decoding",
            "status": "not_returned" if best else "not_found",
            "failure_reason": "return policy threshold not met" if best else "no generated sample with finite score",
            "trace": best.get("trace") if best else "",
            "latency_ms": generation_latency,
            "generated_tokens": generation_tokens,
            "duplicate_count": duplicate_count,
            "oracle_at_n": any(sample["official_verifier"] for sample in oracle_samples),
            "first_gold_rank": first_gold,
            "selected_sample_status": best.get("status") if best else None,
            "selected_sample_index": best.get("sample_index") if best else None,
            "provider_mode": OURS_PROVIDER_MODE,
            "approximation": "none",
            "top_k": None,
            "generation_backend": "racket_generate_hf_sidecar_full_vocab",
        }
    return {
        "candidate_id": int(best["sample_index"]),
        "text": best["text"],
        "lm_logprob": best["lm_logprob"],
        "weak_score": best["guide_score"],
        "guide_score": best["guide_score"],
        "total_score": best["total_score"],
        "returned": True,
        "return_policy": policy_label(return_policy),
        "hybrid_fallback": method == "ours_hybrid_decoding",
        "status": best["status"],
        "failure_reason": best.get("failure_reason") or "",
        "trace": best.get("trace") or "",
        "latency_ms": generation_latency,
        "generated_tokens": generation_tokens,
        "duplicate_count": duplicate_count,
        "oracle_at_n": any(sample["official_verifier"] for sample in oracle_samples),
        "first_gold_rank": first_gold,
        "selected_sample_status": best["status"],
        "selected_sample_index": best["sample_index"],
        "provider_mode": best.get("provider_mode", OURS_PROVIDER_MODE),
        "approximation": best.get("approximation", "none"),
        "top_k": best.get("top_k"),
        "generation_backend": best["generation_backend"],
    }


def run_benchmark() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    rows = read_jsonl(AUDITED_RULES)
    if len(rows) < MIN_AUDITED_ROWS:
        raise SystemExit(f"audited rows {len(rows)} < required {MIN_AUDITED_ROWS}")
    pool = read_jsonl(CANDIDATE_POOL)
    if any("synthetic" in row.get("pool_source", "").lower() for row in pool):
        raise SystemExit("synthetic candidate source is not allowed in Experiment 012")

    row_keys = {row["key"] for row in rows}
    pool_by_key: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for pool_row in pool:
        if pool_row["key"] in row_keys:
            pool_by_key[pool_row["key"]].append(pool_row)
    for key in pool_by_key:
        pool_by_key[key].sort(key=pool_sort_key)
        del pool_by_key[key][max(BUDGETS):]

    raw = []
    missing = []
    score_cache: dict[tuple[str, str, str], float] = {}
    ours_by_key = enriched_ours_samples(rows)

    def score_for(noise: str, row: dict[str, Any], pool_row: dict[str, Any]) -> float:
        key = (noise, row["key"], pool_row["candidate_id"])
        if key not in score_cache:
            score_cache[key] = weak_score_fast(pool_row["text"], row["rule_sets"][noise])
        return score_cache[key]

    for noise in NOISE_LEVELS:
        dev_scores = dev_scores_for(rows, pool_by_key, noise, score_for)
        for policy in POLICIES:
            policy_value = policy_object(policy, dev_scores)
            for n in BUDGETS:
                for method in METHOD_NAMES:
                    if method in OURS_METHODS:
                        ours_policy_value = policy_object(
                            policy,
                            ours_dev_scores(rows, ours_by_key, method, noise, n),
                        )
                        for row in rows:
                            samples = ours_by_key[(method, noise, row["key"])]
                            result = select_ours_method(method, samples, n, ours_policy_value)
                            outcome = Outcome.NOT_FOUND
                            if result["returned"]:
                                selected = samples[int(result["candidate_id"])]
                                outcome = Outcome.FOUND_OK if selected["official_verifier"] else Outcome.FOUND_WRONG
                            raw.append(
                                {
                                    **result,
                                    "example_id": row["key"],
                                    "method": method,
                                    "noise": noise,
                                    "N": n,
                                    "policy": policy,
                                    "outcome": outcome.value,
                                    "split": split_for_key(row["key"]),
                                    "pool_sources": [],
                                    "uses_candidate_pool": False,
                                    "uses_official_verifier_for_selection": False,
                                    "uses_official_verifier_for_outcome": True,
                                    "rule_set_hash": rule_set_hash(row, noise),
                                }
                            )
                        continue
                    for row in rows:
                        indexed = selected_rows(pool_by_key[row["key"]], n)
                        start = time.perf_counter()
                        result = select_pool_method(method, indexed, row, noise, policy_value, score_for)
                        latency_ms = (time.perf_counter() - start) * 1000.0
                        outcome = outcome_for_selected(result, indexed)
                        weak = result["weak_score"]
                        raw.append(
                            {
                                **result,
                                "example_id": row["key"],
                                "method": method,
                                "noise": noise,
                                "N": n,
                                "policy": policy,
                                "outcome": outcome.value,
                                "split": split_for_key(row["key"]),
                                "oracle_at_n": any(item["official_verifier"] for _idx, item in indexed),
                                "first_gold_rank": first_gold_rank(indexed),
                                "latency_ms": latency_ms,
                                "generated_tokens": sum(int(item.get("generated_tokens") or 0) for _idx, item in indexed),
                                "duplicate_count": n - len({item["text"] for _idx, item in indexed}),
                                "pool_sources": sorted({item["pool_source"] for _idx, item in indexed}),
                                "generation_backend": "real_qwen_candidate_pool",
                                "uses_candidate_pool": True,
                                "uses_official_verifier_for_selection": method == "oracle_verifier_selection",
                                "uses_official_verifier_for_outcome": True,
                                "weak_score": weak,
                            }
                        )
    summary = summarize(raw)
    risk = risk_coverage(raw)
    return raw, summary, risk, missing


def missing_ours_rows(method: str, noise: str, n: int, policy: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    smoke_status = "missing"
    if SMOKE_RAW.exists():
        smoke_rows = read_jsonl(SMOKE_RAW)
        smoke_status = ",".join(sorted(set(str(row.get("status")) for row in smoke_rows))) or "empty"
    return [
        {
            "method": method,
            "noise": noise,
            "N": n,
            "policy": policy,
            "expected": len(rows),
            "actual": 0,
            "reason": "generation-time Racket soft decoding is not substituted with candidate-pool posthoc selection",
            "smoke_artifact": str(SMOKE_RAW),
            "smoke_status": smoke_status,
        }
    ]


def summarize(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple, list[dict[str, Any]]] = defaultdict(list)
    for row in raw:
        groups[(row["method"], row["noise"], row["N"], row["policy"], row["split"])].append(row)
    summary = []
    for (method, noise, n, policy, split), rows in sorted(groups.items()):
        counts = Counter(row["outcome"] for row in rows)
        total = len(rows)
        returned = counts["FOUND_OK"] + counts["FOUND_WRONG"]
        oracle_rate = sum(1 for row in rows if row["oracle_at_n"]) / total
        found_ok = counts["FOUND_OK"] / total
        summary.append(
            {
                "method": method,
                "noise": noise,
                "N": n,
                "policy": policy,
                "split": split,
                "total": total,
                "FoundOK": found_ok,
                "FoundWrong": counts["FOUND_WRONG"] / total,
                "NotFound": counts["NOT_FOUND"] / total,
                "ReturnPrecision": (counts["FOUND_OK"] / returned) if returned else "",
                "Coverage": returned / total,
                "OracleAtN": oracle_rate,
                "SelectionEfficiencyAtN": (found_ok / oracle_rate) if oracle_rate else "",
                "FirstGoldRank": median_nullable([row["first_gold_rank"] for row in rows]),
                "AUROC": auroc(rows),
                "AUPRC": auprc(rows),
                "median_latency_ms": statistics.median(row["latency_ms"] for row in rows),
                "mean_generated_tokens": sum(row["generated_tokens"] for row in rows) / total,
                "duplicate_rate_at_N": sum(row["duplicate_count"] for row in rows) / (total * max(1, n)),
            }
        )
    return summary


def risk_coverage(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    for (method, noise, n, split), group in groupby_risk_key(raw).items():
        returned = sorted(
            [row for row in group if row["returned"] and row["weak_score"] is not None],
            key=lambda row: row["weak_score"],
            reverse=True,
        )
        for prefix in range(1, len(returned) + 1):
            subset = returned[:prefix]
            found_ok = sum(1 for row in subset if row["outcome"] == "FOUND_OK")
            found_wrong = sum(1 for row in subset if row["outcome"] == "FOUND_WRONG")
            rows.append(
                {
                    "method": method,
                    "noise": noise,
                    "N": n,
                    "split": split,
                    "threshold_rank": prefix,
                    "threshold_score": subset[-1]["weak_score"],
                    "FoundOK": found_ok / len(group),
                    "FoundWrong": found_wrong / len(group),
                    "Coverage": len(subset) / len(group),
                    "SafeSolveAt5": (found_ok / len(group)) if (found_wrong / len(group)) <= 0.05 else "",
                }
            )
    return rows


def groupby_risk_key(raw: list[dict[str, Any]]) -> dict[tuple, list[dict[str, Any]]]:
    groups: dict[tuple, list[dict[str, Any]]] = defaultdict(list)
    for row in raw:
        if row["policy"] == "risk_target:0.05":
            groups[(row["method"], row["noise"], row["N"], row["split"])].append(row)
    return groups


def median_nullable(values: list[int | None]):
    present = [value for value in values if value is not None]
    return statistics.median(present) if present else ""


def auroc(rows: list[dict[str, Any]]):
    pairs = [(row["weak_score"], row["outcome"] == "FOUND_OK") for row in rows if row["weak_score"] is not None]
    positives = [score for score, label in pairs if label]
    negatives = [score for score, label in pairs if not label]
    if not positives or not negatives:
        return ""
    wins = 0.0
    for pos in positives:
        for neg in negatives:
            wins += 1.0 if pos > neg else 0.5 if pos == neg else 0.0
    return wins / (len(positives) * len(negatives))


def auprc(rows: list[dict[str, Any]]):
    pairs = sorted([(row["weak_score"], row["outcome"] == "FOUND_OK") for row in rows if row["weak_score"] is not None], reverse=True)
    if not any(label for _score, label in pairs):
        return ""
    tp = 0
    precisions = []
    total_pos = sum(1 for _score, label in pairs if label)
    for rank, (_score, label) in enumerate(pairs, 1):
        if label:
            tp += 1
            precisions.append(tp / rank)
    return sum(precisions) / total_pos


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(rows[0].keys()) if rows else []
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_outputs(raw, summary, risk, missing, output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_jsonl(output_dir / RAW_NAME, raw)
        write_csv(output_dir / SUMMARY_NAME, summary)
        write_csv(output_dir / RISK_NAME, risk)
        (output_dir / MISSING_NAME).write_text(json.dumps(missing, indent=2, sort_keys=True), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    raw, summary, risk, missing = run_benchmark()
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(raw, summary, risk, missing, output_dirs)
    print(json.dumps({"raw_rows": len(raw), "summary_rows": len(summary), "risk_rows": len(risk), "missing_runs": len(missing)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
