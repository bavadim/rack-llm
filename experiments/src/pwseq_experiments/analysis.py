from __future__ import annotations

import csv
import json
import math
import os
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import numpy as np

from .common import ARTIFACTS, DATA, assert_frozen, issue, load_config, read_jsonl, run_state, set_run_state, write_json, write_jsonl
from .metrics import (
    average_precision, calibration_bins, common_coverage_metrics, corrected_bootstrap_p,
    operating_metrics, selective_curve,
)


def _accepts_threshold(row: dict[str, Any], decision: dict[str, Any]) -> bool:
    mode = decision["accept_if"]
    if mode == "always":
        return True
    if mode == "never":
        return False
    if mode == "confidence_gte":
        return float(row["confidence"]) >= float(decision["threshold"])
    raise RuntimeError(f"unknown threshold decision: {mode}")


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = sorted(set().union(*(row.keys() for row in rows))) if rows else []
    with tempfile.NamedTemporaryFile(
        "w", newline="", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _macro_aggregation(path: Path) -> list[dict[str, Any]]:
    rows = [
        row for row in read_jsonl(path)
        if row.get("family") != "__ALL__" and "auprc" in row
    ]
    output = []
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[(row["split"], row["aggregator"])].append(row)
    for (split, aggregator), items in sorted(groups.items()):
        output.append({
            "split": split, "aggregator": aggregator,
            **{
                metric: float(np.nanmean([row[metric] for row in items]))
                for metric in ["auprc", "auroc", "nll", "brier", "ece"]
            },
            "families": len(items),
        })
    blocked = [
        row for row in read_jsonl(path)
        if str(row.get("aggregator", "")).startswith("fuse_style") and "auprc" not in row
    ]
    for row in blocked:
        output.append({
            "split": row["split"], "aggregator": "fuse_style_reimplementation",
            "status": row["status"],
        })
    return output


def _rule_table(path: Path) -> list[dict[str, Any]]:
    rows = read_jsonl(path)
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[row["family"]].append(row)
    output = []
    for family, items in sorted(grouped.items()):
        output.append({
            "family": family, "rules": len(items),
            "coverage": float(np.mean([row["coverage"] for row in items])),
            "precision_positive": float(np.nanmean([
                row["precision_positive"] if row["precision_positive"] is not None else np.nan
                for row in items
            ])),
            "precision_negative": float(np.nanmean([
                row["precision_negative"] if row["precision_negative"] is not None else np.nan
                for row in items
            ])),
            "conflict": items[0]["conflict_rate"],
            "effective_rank": items[0]["effective_rank"],
            "gold_valid": items[0]["gold_valid"],
            "gold_invalid": items[0]["gold_invalid"],
        })
    return output


def _generation_table(path: Path, *, split: str = "test_generated", policy: str = "operational") -> list[dict[str, Any]]:
    rows = [
        row for row in read_jsonl(path)
        if row["split"] == split and row["policy"] == policy
        and row.get("aggregation") == "macro"
    ]
    return [{
        "method": row["method"], "budget": row["budget"],
        "solve_rate": row["solve_rate"], "risk": row.get("risk"),
        "coverage": row["coverage"],
        "found_ok": row["found_ok"], "found_wrong": row["found_wrong"],
        "not_found": row["not_found"], "tokens_per_ok": row["tokens_per_ok"],
    } for row in rows]


def _mixed_table(path: Path) -> list[dict[str, Any]]:
    rows = [
        row for row in read_jsonl(path)
        if row["split"] == "test_generated" and row["policy"] == "operational"
        and row.get("aggregation") == "family"
    ]
    return [{
        "constraint_family": row["family"].split("@", 1)[0],
        "hard_arm": row["family"].split("@", 1)[1],
        "method": row["method"], "budget": row["budget"],
        "solve_rate": row["solve_rate"], "risk": row["risk"],
        "coverage": row["coverage"], "tokens_per_ok": row["tokens_per_ok"],
    } for row in rows]


def _pass_at_five() -> list[dict[str, Any]]:
    raw_path = ARTIFACTS / "results" / "main_noise_00_generation_raw.jsonl"
    threshold_path = ARTIFACTS / "thresholds" / "main_noise_00.jsonl"
    if not raw_path.exists() or not threshold_path.exists():
        return []
    thresholds = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(threshold_path)
    }
    groups: dict[tuple[str, int, str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in read_jsonl(raw_path):
        if row["split"] == "test_generated":
            groups[(row["method"], int(row["budget"]), row["family"], row["prompt_id"])].append(row)
    family_values: dict[tuple[str, int, str], list[bool]] = defaultdict(list)
    for (method, budget, family, _prompt), values in groups.items():
        decision = thresholds[(method, budget)]
        solved = any(
            row["outcome"] == "FOUND_OK"
            and _accepts_threshold(row, decision)
            for row in values
        )
        family_values[(method, budget, family)].append(solved)
    output = []
    for method, budget in sorted({(key[0], key[1]) for key in family_values}):
        rates = [
            float(np.mean(values)) for (candidate, candidate_budget, _), values in family_values.items()
            if candidate == method and candidate_budget == budget
        ]
        output.append({
            "metric": "pass_at_5_secondary", "method": method, "budget": budget,
            "macro_rate": float(np.mean(rates)), "families": len(rates),
        })
    return output


def _bootstrap_aggregation() -> list[dict[str, Any]]:
    config = load_config()
    tail = (1.0 - float(config["confidence"])) / 2.0
    scores_path = ARTIFACTS / "scores" / "main_noise_00.jsonl"
    labels_path = ARTIFACTS / "labels" / "main_candidate_labels.jsonl"
    if not scores_path.exists() or not labels_path.exists():
        return []
    gold = {row["candidate_id"]: int(row["gold_pass"]) for row in read_jsonl(labels_path)}
    rows = [
        row for row in read_jsonl(scores_path)
        if row.get("record_type") == "score" and row["split"] == "test_generated"
        and row.get("candidate_id") in gold
    ]
    by_family_prompt: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        by_family_prompt[row["family"]][row["prompt_id"]].append(row)
    rng = np.random.default_rng(config["dataset_seed"])
    methods = {
        "equal_signed_sum": lambda row: 1 / (1 + math.exp(-sum(row["labels"]))),
        "majority_vote": lambda row: (
            (sum(value > 0 for value in row["labels"]) + 1)
            / (sum(value != 0 for value in row["labels"]) + 2)
        ),
        "polarity_weak_model": lambda row: float(row["posterior"]),
    }

    def macro(selected: dict[str, list[list[dict[str, Any]]]], method: str) -> float:
        values = []
        for family, prompt_groups in selected.items():
            flat = [row for group in prompt_groups for row in group]
            y = np.asarray([gold[row["candidate_id"]] for row in flat])
            p = np.asarray([methods[method](row) for row in flat])
            values.append(average_precision(y, p))
        return float(np.nanmean(values))

    diffs = {"equal_signed_sum": [], "majority_vote": []}
    for _ in range(config["bootstrap_repetitions"]):
        selected = {}
        for family, prompts in by_family_prompt.items():
            groups = list(prompts.values())
            indices = rng.integers(0, len(groups), size=len(groups))
            selected[family] = [groups[index] for index in indices]
        weak = macro(selected, "polarity_weak_model")
        for baseline in diffs:
            diffs[baseline].append(weak - macro(selected, baseline))
    output = []
    for baseline, values in diffs.items():
        array = np.asarray(values)
        output.append({
            "comparison": f"polarity_weak_model-minus-{baseline}",
            "metric": "macro_auprc",
            "difference_mean": float(array.mean()),
            "ci_low": float(np.quantile(array, tail)),
            "ci_high": float(np.quantile(array, 1.0 - tail)),
            "bootstrap_p": corrected_bootstrap_p(array),
        })
    return output


def _bootstrap_generation() -> list[dict[str, Any]]:
    config = load_config()
    tail = (1.0 - float(config["confidence"])) / 2.0
    path = ARTIFACTS / "results" / "main_noise_00_generation_raw.jsonl"
    if not path.exists():
        return []
    rows = [
        row for row in read_jsonl(path)
        if row["split"] == "test_generated" and row["budget"] == 8
    ]
    threshold_path = ARTIFACTS / "thresholds" / "main_noise_00.jsonl"
    if not threshold_path.exists():
        return []
    thresholds = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(threshold_path) if row["source_split"] == "dev"
    }
    expected_seeds = set(map(int, config["generation_seeds"]))

    def grouped(apply_threshold: bool) -> dict[str, dict[str, dict[str, Any]]]:
        source: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
        for original in rows:
            row = dict(original)
            decision = thresholds.get((row["method"], 8)) if apply_threshold else None
            if (decision is not None and row["outcome"] != "NOT_FOUND"
                    and not _accepts_threshold(row, decision)):
                row["outcome"] = "NOT_FOUND"
            source[row["method"]][row["prompt_id"]].append(row)
        output: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
        for method, prompts in source.items():
            for prompt, values in prompts.items():
                seeds = [int(row["seed"]) for row in values]
                if len(seeds) != len(set(seeds)) or set(seeds) != expected_seeds:
                    raise RuntimeError(f"invalid seed cohort: {method}/{prompt}: {seeds}")
                output[method][prompt] = {
                    "prompt_id": prompt, "family": values[0]["family"],
                    "outcome": "PROMPT_MEAN",
                    "confidence": float(np.mean([float(row["confidence"]) for row in values])),
                    "ok_weight": float(np.mean([row["outcome"] == "FOUND_OK" for row in values])),
                    "wrong_weight": float(np.mean([row["outcome"] == "FOUND_WRONG" for row in values])),
                    "return_weight": float(np.mean([row["outcome"] != "NOT_FOUND" for row in values])),
                }
        return output

    raw_by_method = grouped(False)
    operational_by_method = grouped(True)
    methods = ["hard_only_cars", "equal_score_best_of_b", "posterior_best_of_b"]
    if "exact_pwsg" not in raw_by_method:
        return []
    required = {"exact_pwsg", *methods}
    missing_methods = sorted(required - set(raw_by_method))
    if missing_methods:
        raise RuntimeError(f"missing primary generation methods: {missing_methods}")
    missing_thresholds = sorted(
        method for method in required if (method, 8) not in thresholds
    )
    if missing_thresholds:
        raise RuntimeError(f"missing dev thresholds: {missing_thresholds}")
    prompts_by_family: dict[str, list[str]] = defaultdict(list)
    instance_family = {
        row["id"]: row["family"] for row in read_jsonl(DATA / "test_generated.jsonl")
    }
    for prompt in raw_by_method["exact_pwsg"]:
        prompts_by_family[instance_family[prompt]].append(prompt)
    rng = np.random.default_rng(config["dataset_seed"] + 1)
    diffs = {method: [] for method in methods if method in raw_by_method}
    safe_diffs = {method: [] for method in diffs}

    def macro_metrics(selected: list[str], method: str) -> tuple[float, float]:
        paurc = []
        solve = []
        for family in sorted(prompts_by_family):
            family_prompts = [prompt for prompt in selected if instance_family[prompt] == family]
            curves = {
                candidate: selective_curve([raw_by_method[candidate][prompt] for prompt in family_prompts])
                for candidate in ["hard_only_cars", "equal_score_best_of_b", "posterior_best_of_b", "exact_pwsg"]
                if candidate in raw_by_method
            }
            common = common_coverage_metrics(curves)
            value = common[method]["normalized_partial_aurc"]
            if value is None:
                raise RuntimeError(f"zero common coverage for {family}/{method}")
            paurc.append(value)
            op = [operational_by_method[method][prompt] for prompt in family_prompts]
            solve.append(float(np.mean([row["ok_weight"] for row in op])))
        return float(np.mean(paurc)), float(np.mean(solve))

    for _ in range(config["bootstrap_repetitions"]):
        sampled = []
        for family, prompts in prompts_by_family.items():
            indices = rng.integers(0, len(prompts), size=len(prompts))
            sampled.extend(prompts[index] for index in indices)
        ours_aurc, ours_safe = macro_metrics(sampled, "exact_pwsg")
        for method in diffs:
            baseline_aurc, baseline_safe = macro_metrics(sampled, method)
            diffs[method].append(ours_aurc - baseline_aurc)
            safe_diffs[method].append(ours_safe - baseline_safe)
    output = []
    for method, values in diffs.items():
        array = np.asarray(values)
        safe = np.asarray(safe_diffs[method])
        output.append({
            "comparison": f"exact_pwsg-minus-{method}",
            "metric": "normalized_common_coverage_paurc",
            "paurc_difference_mean": float(array.mean()),
            "paurc_ci_low": float(np.quantile(array, tail)),
            "paurc_ci_high": float(np.quantile(array, 1.0 - tail)),
            "operational_solve_rate_difference_mean": float(safe.mean()),
            "solve_rate_ci_low": float(np.quantile(safe, tail)),
            "solve_rate_ci_high": float(np.quantile(safe, 1.0 - tail)),
            "bootstrap_p": corrected_bootstrap_p(array),
        })
        seed0 = min(expected_seeds)
        def solved_seed0(row: dict[str, Any]) -> bool:
            decision = thresholds[(row["method"], 8)]
            returned = row["outcome"] != "NOT_FOUND" and _accepts_threshold(row, decision)
            return returned and row["outcome"] == "FOUND_OK"
        ours_solved = {
            row["prompt_id"]: solved_seed0(row)
            for row in rows if row["method"] == "exact_pwsg" and int(row["seed"]) == seed0
        }
        baseline_solved = {
            row["prompt_id"]: solved_seed0(row)
            for row in rows if row["method"] == method and int(row["seed"]) == seed0
        }
        common = sorted(ours_solved.keys() & baseline_solved.keys())
        ours_only = sum(ours_solved[prompt] and not baseline_solved[prompt] for prompt in common)
        baseline_only = sum(baseline_solved[prompt] and not ours_solved[prompt] for prompt in common)
        discordant = ours_only + baseline_only
        if discordant:
            from scipy.stats import binomtest
            output[-1]["mcnemar_exact_p"] = float(
                binomtest(min(ours_only, baseline_only), discordant, .5).pvalue
            )
            output[-1]["mcnemar_ours_only"] = ours_only
            output[-1]["mcnemar_baseline_only"] = baseline_only
    return output


def _holm(rows: list[dict[str, Any]]) -> None:
    indexed = sorted(
        [(index, row["bootstrap_p"]) for index, row in enumerate(rows) if "bootstrap_p" in row],
        key=lambda item: item[1],
    )
    running = 0.0
    count = len(indexed)
    for rank, (index, pvalue) in enumerate(indexed):
        running = max(running, min(1.0, (count - rank) * pvalue))
        rows[index]["holm_p"] = running


def _figures() -> None:
    import matplotlib.pyplot as plt
    import pandas as pd

    figure_dir = ARTIFACTS / "figures"
    figure_dir.mkdir(parents=True, exist_ok=True)
    raw_path = ARTIFACTS / "results" / "main_noise_00_generation_raw.jsonl"
    if raw_path.exists():
        raw = read_jsonl(raw_path)
        plt.figure()
        for method in ["hard_only_cars", "equal_score_best_of_b", "posterior_best_of_b", "exact_pwsg"]:
            rows = [row for row in raw if row["split"] == "test_generated" and row["budget"] == 8 and row["method"] == method]
            if rows:
                curve = selective_curve(rows)
                plt.plot([x["coverage"] for x in curve], [x["risk"] for x in curve], label=method)
        plt.xlabel("Coverage"); plt.ylabel("Risk"); plt.legend(); plt.tight_layout()
        plt.savefig(figure_dir / "risk_coverage.png", dpi=180); plt.close()

    summaries = []
    for level in [0, 20, 40]:
        path = ARTIFACTS / "results" / f"main_noise_{level:02d}_generation_summary.jsonl"
        if path.exists():
            summaries.extend(read_jsonl(path))
    if summaries:
        frame = pd.DataFrame(summaries)
        subset = frame[
            (frame["split"] == "test_generated")
            & (frame["policy"] == "operational")
            & (frame["aggregation"] == "macro")
        ]
        plt.figure()
        for method, group in subset.groupby("method"):
            clean = group[group["noise"] == 0]
            if len(clean):
                clean = clean.sort_values("mean_model_tokens")
                plt.plot(clean["mean_model_tokens"], clean["solve_rate"], marker="o", label=method)
        plt.xlabel("Mean model-token draws"); plt.ylabel("Solve rate at dev-selected threshold"); plt.legend(); plt.tight_layout()
        plt.savefig(figure_dir / "quality_vs_budget.png", dpi=180); plt.close()

        plt.figure()
        for method, group in subset[subset["budget"] == 8].groupby("method"):
            plt.plot(group["noise"], group["solve_rate"], marker="o", label=method)
        plt.xlabel("Noise"); plt.ylabel("Solve rate at dev-selected threshold"); plt.legend(); plt.tight_layout()
        plt.savefig(figure_dir / "noise_robustness.png", dpi=180); plt.close()

        plt.figure()
        for method, group in subset[subset["budget"] == 8].groupby("method"):
            total = group["prompts_x_seeds"]
            plt.plot(group["noise"], group["found_wrong"] / total, marker="o", label=f"{method}:wrong")
            plt.plot(group["noise"], group["not_found"] / total, marker="x", linestyle="--", label=f"{method}:abstain")
        plt.xlabel("Noise"); plt.ylabel("Rate"); plt.legend(fontsize=6); plt.tight_layout()
        plt.savefig(figure_dir / "found_wrong_vs_not_found.png", dpi=180); plt.close()

    scores_path = ARTIFACTS / "scores" / "main_noise_00.jsonl"
    labels_path = ARTIFACTS / "labels" / "main_candidate_labels.jsonl"
    if scores_path.exists() and labels_path.exists():
        gold = {row["candidate_id"]: int(row["gold_pass"]) for row in read_jsonl(labels_path)}
        rows = [row for row in read_jsonl(scores_path) if row.get("record_type") == "score" and row["split"] == "test_generated" and row.get("candidate_id") in gold]
        y = np.asarray([gold[row["candidate_id"]] for row in rows], dtype=int)
        p = np.asarray([row["posterior"] for row in rows], dtype=float)
        groups = calibration_bins(y, p, bins=load_config()["ece_bins"])
        write_jsonl(figure_dir / "reliability_data.jsonl", groups)
        plt.figure()
        for group in groups:
            plt.scatter(group["mean_probability"], group["empirical_rate"],
                        s=max(12, math.sqrt(group["count"]) * 3), color="C0")
        plt.plot([0, 1], [0, 1], color="black", linestyle="--")
        plt.xlabel("Posterior"); plt.ylabel("Empirical accuracy"); plt.tight_layout()
        plt.savefig(figure_dir / "reliability.png", dpi=180); plt.close()


def analyze() -> None:
    assert_frozen()
    if run_state() != "RUN_COMPLETE":
        raise RuntimeError(f"analysis requires RUN_COMPLETE state, got {run_state()}")
    tables = ARTIFACTS / "tables"
    statistics = []
    audit = ARTIFACTS / "reports" / "main_noise_00_rule_audit.jsonl"
    if audit.exists():
        _write_csv(tables / "table1_rules.csv", _rule_table(audit))
    aggregation = ARTIFACTS / "reports" / "main_noise_00_aggregation.jsonl"
    if aggregation.exists():
        _write_csv(tables / "table2_aggregation.csv", _macro_aggregation(aggregation))
    generation = ARTIFACTS / "results" / "main_noise_00_generation_summary.jsonl"
    if generation.exists():
        _write_csv(tables / "table3_generation.csv", _generation_table(generation))
        _write_csv(tables / "table3b_pass_at_5_secondary.csv", _pass_at_five())
    mixed = ARTIFACTS / "results" / "main_mixed_noise_00_generation_summary.jsonl"
    if mixed.exists():
        _write_csv(tables / "table5_mixed_hard_weak.csv", _mixed_table(mixed))
    noise_rows = []
    for level in [0, 20, 40]:
        path = ARTIFACTS / "results" / f"main_noise_{level:02d}_generation_summary.jsonl"
        if path.exists():
            noise_rows.extend([
                row for row in read_jsonl(path)
                if row["split"] == "test_generated" and row["policy"] == "operational"
                and row.get("aggregation") == "macro"
            ])
    if noise_rows:
        _write_csv(tables / "table4_noise.csv", noise_rows)

    aggregation_stats = _bootstrap_aggregation()
    generation_stats = _bootstrap_generation()
    statistics.extend(aggregation_stats + generation_stats)
    _holm(statistics)
    write_jsonl(tables / "statistical_tests.jsonl", statistics)

    claims = []
    synthetic = ARTIFACTS / "hard" / "synthetic_summary.json"
    hard_summary = ARTIFACTS / "hard" / "hard_sanity_summary.jsonl"
    if synthetic.exists() and hard_summary.exists():
        synthetic_ok = json.loads(synthetic.read_text())["success"]
        cars = next((row for row in read_jsonl(hard_summary) if row["method"] == "cars"), None)
        claims.append({
            "claim": 1,
            "status": "SUPPORTED" if synthetic_ok and cars and cars["invalid_return_rate"] == 0 else "NOT_SUPPORTED",
        })
    else:
        claims.append({"claim": 1, "status": "BLOCKED"})

    filter_path = ARTIFACTS / "reports" / "main_noise_00_filter.json"
    if filter_path.exists() and audit.exists():
        filtered = json.loads(filter_path.read_text())
        rule_rows = _rule_table(audit)
        raw_audit = read_jsonl(audit)
        polarity_counts = defaultdict(Counter)
        for row in raw_audit:
            polarity_counts[row["family"]][row.get("polarity")] += 1
        eligible = all(
            len(filtered["selected_slots"].get(row["family"], [])) >= 5
            and polarity_counts[row["family"]]["positive"] >= 2
            and polarity_counts[row["family"]]["negative"] >= 1
            and row["conflict"] > 0 and row["gold_valid"] >= 50 and row["gold_invalid"] >= 50
            for row in rule_rows
        ) and len(rule_rows) == 12
        claims.append({"claim": 2, "status": "SUPPORTED" if eligible else "NOT_SUPPORTED"})
    else:
        claims.append({"claim": 2, "status": "BLOCKED"})

    if aggregation_stats:
        supported = all(row["ci_low"] > 0 and row.get("holm_p", 1) < .05 for row in aggregation_stats)
        claims.append({"claim": 3, "status": "SUPPORTED" if supported else "NOT_SUPPORTED"})
    else:
        claims.append({"claim": 3, "status": "BLOCKED"})

    if generation_stats:
        broad = [row for row in generation_stats if row["comparison"].endswith(("hard_only_cars", "equal_score_best_of_b"))]
        direct = next((row for row in generation_stats if row["comparison"].endswith("posterior_best_of_b")), None)
        broad_ok = bool(broad) and all(row["paurc_ci_high"] < 0 and row.get("holm_p", 1) < .05 for row in broad)
        direct_ok = bool(direct) and direct["paurc_ci_high"] < 0 and direct.get("holm_p", 1) < .05
        claims.append({"claim": "4a", "status": "SUPPORTED" if broad_ok else "NOT_SUPPORTED"})
        claims.append({"claim": "4b", "status": "SUPPORTED" if direct_ok else "NOT_SUPPORTED"})
    else:
        claims.append({"claim": 4, "status": "BLOCKED"})
    write_json(ARTIFACTS / "CLAIMS.json", claims)

    issues_path = ARTIFACTS / "issues.jsonl"
    issue_counts = Counter(row["stage"] for row in read_jsonl(issues_path)) if issues_path.exists() else Counter()
    lines = ["# Experimental status", "", "## Claims", ""]
    lines.extend(f"- Claim {row['claim']}: **{row['status']}**" for row in claims)
    lines.extend(["", "## Recorded issues", ""])
    lines.extend(f"- `{stage}`: {count}" for stage, count in sorted(issue_counts.items()))
    status_path = ARTIFACTS / "STATUS.md"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=status_path.parent,
        prefix=f".{status_path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write("\n".join(lines) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, status_path)
    try:
        _figures()
    except Exception as exc:
        issue("analysis.figures", exc)
        raise
    set_run_state("ANALYZED")
    set_run_state("READY_TO_ARCHIVE")
