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

from .common import ARTIFACTS, assert_frozen, issue, load_config, read_jsonl, run_state, set_run_state, write_json, write_jsonl
from .metrics import (
    average_precision, common_coverage_metrics, corrected_bootstrap_p,
    risks_at_coverages, selective_curve,
)
from .reporting import generation_scalar_data, prompt_generation_records, reliability_data


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


def _temperature_ablation_table(path: Path) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in read_jsonl(path):
        groups[(row["split"], row["variant"])].append(row)
    output = []
    for (split, variant), rows in sorted(groups.items()):
        temperatures = {tuple(row["fit_temperatures"]) for row in rows}
        evaluation = {float(row["evaluation_temperature"]) for row in rows}
        if len(temperatures) != 1 or len(evaluation) != 1:
            raise RuntimeError(f"inconsistent temperature ablation policy: {split}/{variant}")
        output.append({
            "split": split,
            "variant": variant,
            "fit_temperatures": ",".join(map(str, next(iter(temperatures)))),
            "evaluation_temperature": next(iter(evaluation)),
            **{
                metric: float(np.nanmean([row[metric] for row in rows]))
                for metric in ["auprc", "auroc", "nll", "brier", "ece"]
            },
            "families": len(rows),
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


def _mixed_table(path: Path) -> list[dict[str, Any]]:
    rows = [
        row for row in read_jsonl(path)
        if row["split"] == "test" and row["policy"] == "operational"
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
        if row["split"] == "test":
            groups[(row["method"], int(row["budget"]), row["family"], row["prompt_id"])].append(row)
    family_values: dict[tuple[str, int, str], list[bool]] = defaultdict(list)
    expected_seeds = set(map(int, load_config()["generation_seeds"]))
    if len(expected_seeds) != 5:
        raise RuntimeError("pass@5 requires exactly five configured generation seeds")
    for (method, budget, family, _prompt), values in groups.items():
        seeds = [int(row["seed"]) for row in values]
        if len(seeds) != len(set(seeds)) or set(seeds) != expected_seeds:
            raise RuntimeError(
                f"invalid pass@5 seed cohort: {method}/{budget}/{_prompt}: {seeds}"
            )
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
        if row.get("record_type") == "score" and row["split"] == "test"
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


def _bootstrap_generation_bundle() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    config = load_config()
    tail = (1.0 - float(config["confidence"])) / 2.0
    path = ARTIFACTS / "results" / "main_noise_00_generation_raw.jsonl"
    threshold_path = ARTIFACTS / "thresholds" / "main_noise_00.jsonl"
    if not path.exists() or not threshold_path.exists():
        return [], []
    rows = [
        row for row in read_jsonl(path)
        if row["split"] == "test" and int(row["budget"]) == 8
    ]
    thresholds = {
        (row["method"], int(row["budget"])): row
        for row in read_jsonl(threshold_path) if row["source_split"] == "dev"
    }
    expected_seeds = set(map(int, config["generation_seeds"]))
    raw_records = prompt_generation_records(rows, expected_seeds=expected_seeds)
    operational_records = prompt_generation_records(
        rows, expected_seeds=expected_seeds, decisions=thresholds,
        accepts=_accepts_threshold,
    )
    raw_by_method: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    operational_by_method: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for row in raw_records:
        raw_by_method[row["method"]][row["prompt_id"]] = row
    for row in operational_records:
        operational_by_method[row["method"]][row["prompt_id"]] = row

    baselines = ["hard_only_cars", "equal_score_best_of_b", "posterior_best_of_b"]
    central = [*baselines, "exact_pwsg"]
    missing = sorted(set(central) - set(raw_by_method))
    if missing:
        raise RuntimeError(f"missing primary generation methods: {missing}")
    missing_thresholds = sorted(
        method for method in central if (method, 8) not in thresholds
    )
    if missing_thresholds:
        raise RuntimeError(f"missing dev thresholds: {missing_thresholds}")
    reference = raw_by_method["exact_pwsg"]
    instance_family = {prompt: row["family"] for prompt, row in reference.items()}
    reference_prompts = set(reference)
    prompts_by_family: dict[str, list[str]] = defaultdict(list)
    for prompt, family in instance_family.items():
        prompts_by_family[family].append(prompt)
    for prompts in prompts_by_family.values():
        prompts.sort()
    for method in central:
        candidate_prompts = set(raw_by_method[method])
        if candidate_prompts != reference_prompts:
            raise RuntimeError(
                f"unpaired prompt set for {method}: "
                f"missing={sorted(reference_prompts - candidate_prompts)[:5]}, "
                f"extra={sorted(candidate_prompts - reference_prompts)[:5]}"
            )
        if any(
            raw_by_method[method][prompt]["family"] != instance_family[prompt]
            for prompt in reference_prompts
        ):
            raise RuntimeError(f"inconsistent family assignment for {method}")

    def curves_for(sampled: dict[str, list[str]]) -> dict[str, dict[str, list[dict[str, float]]]]:
        return {
            family: {
                method: selective_curve([
                    raw_by_method[method][prompt] for prompt in family_prompts
                ])
                for method in central
            }
            for family, family_prompts in sampled.items()
        }

    full_curves = curves_for(prompts_by_family)
    common_limit = min(
        max(point["coverage"] for point in curve)
        for curves in full_curves.values() for curve in curves.values()
    )
    if common_limit <= 0:
        raise RuntimeError("zero common coverage for primary risk-coverage figure")
    coverage_grid = np.linspace(0.0, common_limit, 101)
    point_risk = {
        method: np.mean(np.stack([
            risks_at_coverages(full_curves[family][method], coverage_grid)
            for family in sorted(full_curves)
        ]), axis=0)
        for method in central
    }

    repetitions = int(config["bootstrap_repetitions"])
    rng = np.random.default_rng(config["dataset_seed"] + 1)
    diffs = {method: [] for method in baselines}
    safe_diffs = {method: [] for method in baselines}
    risk_samples = {
        method: np.full((repetitions, len(coverage_grid)), np.nan)
        for method in central
    }
    support = np.zeros(len(coverage_grid), dtype=int)
    for repetition in range(repetitions):
        sampled: dict[str, list[str]] = {}
        for family, prompts in prompts_by_family.items():
            indices = rng.integers(0, len(prompts), size=len(prompts))
            sampled[family] = [prompts[index] for index in indices]
        sampled_curves = curves_for(sampled)
        paurc: dict[str, list[float]] = defaultdict(list)
        solve: dict[str, list[float]] = defaultdict(list)
        paurc_supported = True
        for family, family_prompts in sampled.items():
            common = common_coverage_metrics(sampled_curves[family])
            for method in central:
                value = common[method]["normalized_partial_aurc"]
                if value is None:
                    paurc_supported = False
                else:
                    paurc[method].append(float(value))
                solve[method].append(float(np.mean([
                    operational_by_method[method][prompt]["ok_weight"]
                    for prompt in family_prompts
                ])))
        if paurc_supported:
            ours_aurc = float(np.mean(paurc["exact_pwsg"]))
            ours_solve = float(np.mean(solve["exact_pwsg"]))
            for method in baselines:
                diffs[method].append(ours_aurc - float(np.mean(paurc[method])))
                safe_diffs[method].append(ours_solve - float(np.mean(solve[method])))
        method_risks: dict[str, np.ndarray] = {}
        supported = np.ones(len(coverage_grid), dtype=bool)
        for method in central:
            family_values = np.stack([
                risks_at_coverages(sampled_curves[family][method], coverage_grid)
                for family in sorted(sampled_curves)
            ])
            supported &= np.isfinite(family_values).all(axis=0)
            method_risks[method] = np.mean(family_values, axis=0)
        support[supported] += 1
        for method, values in method_risks.items():
            risk_samples[method][repetition, supported] = values[supported]

    output = []
    seed0 = min(expected_seeds)

    def solved_seed0(row: dict[str, Any]) -> bool:
        decision = thresholds[(row["method"], 8)]
        returned = row["outcome"] != "NOT_FOUND" and _accepts_threshold(row, decision)
        return returned and row["outcome"] == "FOUND_OK"

    for method in baselines:
        array = np.asarray(diffs[method])
        safe = np.asarray(safe_diffs[method])
        if len(array) < math.ceil(.95 * repetitions):
            raise RuntimeError(
                f"insufficient bootstrap support for exact_pwsg-minus-{method}: "
                f"{len(array)}/{repetitions}"
            )
        result = {
            "comparison": f"exact_pwsg-minus-{method}",
            "metric": "normalized_common_coverage_paurc",
            "paurc_difference_mean": float(array.mean()),
            "paurc_ci_low": float(np.quantile(array, tail)),
            "paurc_ci_high": float(np.quantile(array, 1.0 - tail)),
            "operational_solve_rate_difference_mean": float(safe.mean()),
            "solve_rate_ci_low": float(np.quantile(safe, tail)),
            "solve_rate_ci_high": float(np.quantile(safe, 1.0 - tail)),
            "bootstrap_p": corrected_bootstrap_p(array),
            "bootstrap_repetitions": repetitions,
            "bootstrap_support": len(array),
        }
        ours_solved = {
            row["prompt_id"]: solved_seed0(row)
            for row in rows if row["method"] == "exact_pwsg" and int(row["seed"]) == seed0
        }
        baseline_solved = {
            row["prompt_id"]: solved_seed0(row)
            for row in rows if row["method"] == method and int(row["seed"]) == seed0
        }
        common_prompts = sorted(ours_solved.keys() & baseline_solved.keys())
        ours_only = sum(ours_solved[prompt] and not baseline_solved[prompt] for prompt in common_prompts)
        baseline_only = sum(baseline_solved[prompt] and not ours_solved[prompt] for prompt in common_prompts)
        discordant = ours_only + baseline_only
        if discordant:
            from scipy.stats import binomtest
            result.update({
                "mcnemar_exact_p": float(
                    binomtest(min(ours_only, baseline_only), discordant, .5).pvalue
                ),
                "mcnemar_ours_only": ours_only,
                "mcnemar_baseline_only": baseline_only,
            })
        output.append(result)

    minimum_support = math.ceil(.95 * repetitions)
    risk_rows = []
    for grid_index, coverage in enumerate(coverage_grid):
        if support[grid_index] < minimum_support:
            continue
        for method in central:
            values = risk_samples[method][:, grid_index]
            values = values[np.isfinite(values)]
            if not len(values):
                raise RuntimeError(
                    f"risk-coverage grid has no finite bootstrap values: "
                    f"{method}/{coverage}"
                )
            risk_rows.append({
                "method": method, "budget": 8, "noise": 0.0,
                "coverage": float(coverage),
                "risk": float(point_risk[method][grid_index]),
                "risk_ci_low": float(np.quantile(values, tail)),
                "risk_ci_high": float(np.quantile(values, 1.0 - tail)),
                "bootstrap_repetitions": repetitions,
                "bootstrap_support": int(len(values)),
                "bootstrap_support_fraction": float(len(values) / repetitions),
                "confidence_level": float(config["confidence"]),
                "common_coverage_limit": float(common_limit),
                "coverage_grid_points": 101,
            })
    return output, risk_rows


def _bootstrap_generation() -> list[dict[str, Any]]:
    statistics, _ = _bootstrap_generation_bundle()
    return statistics


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


def _build_figure_data(risk_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    config = load_config()
    figure_dir = ARTIFACTS / "figures"
    figure_dir.mkdir(parents=True, exist_ok=True)
    expected_seeds = set(map(int, config["generation_seeds"]))
    prompt_records = []
    for level in [0, 20, 40]:
        raw_path = ARTIFACTS / "results" / f"main_noise_{level:02d}_generation_raw.jsonl"
        threshold_path = ARTIFACTS / "thresholds" / f"main_noise_{level:02d}.jsonl"
        if not raw_path.exists() or not threshold_path.exists():
            raise RuntimeError(f"missing generation reporting inputs for noise {level}")
        thresholds = {
            (row["method"], int(row["budget"])): row
            for row in read_jsonl(threshold_path) if row["source_split"] == "dev"
        }
        rows = [row for row in read_jsonl(raw_path) if row["split"] == "test"]
        collapsed = prompt_generation_records(
            rows, expected_seeds=expected_seeds, decisions=thresholds,
            accepts=_accepts_threshold,
        )
        prompt_records.extend({**row, "noise": level / 100.0} for row in collapsed)
    scalar_rows = generation_scalar_data(
        prompt_records,
        repetitions=int(config["bootstrap_repetitions"]),
        confidence=float(config["confidence"]),
        seed=int(config["dataset_seed"]) + 2,
    )
    quality_rows = [row for row in scalar_rows if row["noise"] == 0.0]
    noise_rows = [row for row in scalar_rows if int(row["budget"]) == 8]
    write_jsonl(figure_dir / "risk_coverage_data.jsonl", risk_rows)
    write_jsonl(figure_dir / "quality_vs_budget_data.jsonl", quality_rows)
    write_jsonl(figure_dir / "noise_robustness_data.jsonl", noise_rows)

    scores_path = ARTIFACTS / "scores" / "main_noise_00.jsonl"
    labels_path = ARTIFACTS / "labels" / "main_candidate_labels.jsonl"
    if not scores_path.exists() or not labels_path.exists():
        raise RuntimeError("missing reliability reporting inputs")
    gold = {row["candidate_id"]: int(row["gold_pass"]) for row in read_jsonl(labels_path)}
    scores = [
        row for row in read_jsonl(scores_path)
        if row.get("record_type") == "score" and row["split"] == "test"
    ]
    reliability_rows = reliability_data(
        scores, gold, bins=int(config["ece_bins"]),
        repetitions=int(config["bootstrap_repetitions"]),
        confidence=float(config["confidence"]),
        seed=int(config["dataset_seed"]) + 3,
    )
    write_jsonl(figure_dir / "reliability_data.jsonl", reliability_rows)
    return scalar_rows


def _errorbar(plt: Any, rows: list[dict[str, Any]], x: str, y: str, **kwargs: Any) -> None:
    values = sorted(rows, key=lambda row: float(row[x]))
    center = np.asarray([row[y] for row in values], dtype=float)
    low = np.asarray([row[f"{y}_ci_low"] for row in values], dtype=float)
    high = np.asarray([row[f"{y}_ci_high"] for row in values], dtype=float)
    plt.errorbar(
        [row[x] for row in values], center,
        yerr=np.vstack((np.maximum(0, center - low), np.maximum(0, high - center))),
        capsize=2, **kwargs,
    )


def _render_figures() -> None:
    """Render PNGs exclusively from the archived machine-readable figure data."""
    import matplotlib.pyplot as plt

    figure_dir = ARTIFACTS / "figures"
    risk_rows = read_jsonl(figure_dir / "risk_coverage_data.jsonl")
    plt.figure()
    for method in sorted({row["method"] for row in risk_rows}):
        rows = sorted(
            (row for row in risk_rows if row["method"] == method),
            key=lambda row: row["coverage"],
        )
        x = np.asarray([row["coverage"] for row in rows])
        y = np.asarray([row["risk"] for row in rows])
        line = plt.plot(x, y, label=method)[0]
        plt.fill_between(
            x, [row["risk_ci_low"] for row in rows],
            [row["risk_ci_high"] for row in rows],
            color=line.get_color(), alpha=.16,
        )
    plt.xlabel("Coverage"); plt.ylabel("Risk"); plt.legend(); plt.tight_layout()
    plt.savefig(figure_dir / "risk_coverage.png", dpi=180); plt.close()

    quality_rows = read_jsonl(figure_dir / "quality_vs_budget_data.jsonl")
    plt.figure()
    for method in sorted({row["method"] for row in quality_rows}):
        _errorbar(
            plt, [row for row in quality_rows if row["method"] == method],
            "mean_model_tokens", "solve_rate", marker="o", label=method,
        )
    plt.xlabel("Mean model-token draws"); plt.ylabel("Solve rate at dev-selected threshold")
    plt.legend(); plt.tight_layout()
    plt.savefig(figure_dir / "quality_vs_budget.png", dpi=180); plt.close()

    noise_rows = read_jsonl(figure_dir / "noise_robustness_data.jsonl")
    plt.figure()
    for method in sorted({row["method"] for row in noise_rows}):
        _errorbar(
            plt, [row for row in noise_rows if row["method"] == method],
            "noise", "solve_rate", marker="o", label=method,
        )
    plt.xlabel("Noise"); plt.ylabel("Solve rate at dev-selected threshold")
    plt.legend(); plt.tight_layout()
    plt.savefig(figure_dir / "noise_robustness.png", dpi=180); plt.close()

    plt.figure()
    for method in sorted({row["method"] for row in noise_rows}):
        method_rows = [row for row in noise_rows if row["method"] == method]
        _errorbar(
            plt, method_rows, "noise", "found_wrong_rate",
            marker="o", label=f"{method}:wrong",
        )
        _errorbar(
            plt, method_rows, "noise", "not_found_rate",
            marker="x", linestyle="--", label=f"{method}:abstain",
        )
    plt.xlabel("Noise"); plt.ylabel("Rate"); plt.legend(fontsize=6); plt.tight_layout()
    plt.savefig(figure_dir / "found_wrong_vs_not_found.png", dpi=180); plt.close()

    reliability_rows = read_jsonl(figure_dir / "reliability_data.jsonl")
    plt.figure()
    for row in reliability_rows:
        center = float(row["empirical_rate"])
        plt.errorbar(
            float(row["mean_probability"]), center,
            yerr=[[max(0.0, center - float(row["empirical_rate_ci_low"]))],
                  [max(0.0, float(row["empirical_rate_ci_high"]) - center)]],
            fmt="o", markersize=max(3, math.sqrt(row["count"]) / 2),
            color="C0", capsize=2,
        )
    plt.plot([0, 1], [0, 1], color="black", linestyle="--")
    plt.xlabel("Posterior"); plt.ylabel("Empirical accuracy"); plt.tight_layout()
    plt.savefig(figure_dir / "reliability.png", dpi=180); plt.close()


def _reporting_generation_table(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    fields = [
        "method", "budget", "solve_rate", "solve_rate_ci_low", "solve_rate_ci_high",
        "risk", "risk_ci_low", "risk_ci_high", "coverage", "coverage_ci_low",
        "coverage_ci_high", "found_wrong_rate", "found_wrong_rate_ci_low",
        "found_wrong_rate_ci_high", "not_found_rate", "not_found_rate_ci_low",
        "not_found_rate_ci_high", "tokens_per_ok", "tokens_per_ok_ci_low",
        "tokens_per_ok_ci_high", "prompts", "families",
    ]
    return [
        {key: row.get(key) for key in fields}
        for row in rows if row["noise"] == 0.0
    ]


def _reporting_noise_table(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    fields = [
        "noise", "method", "budget", "solve_rate", "solve_rate_ci_low",
        "solve_rate_ci_high", "risk", "risk_ci_low", "risk_ci_high",
        "found_wrong_rate", "found_wrong_rate_ci_low", "found_wrong_rate_ci_high",
        "not_found_rate", "not_found_rate_ci_low", "not_found_rate_ci_high",
        "prompts", "families",
    ]
    return [
        {key: row.get(key) for key in fields}
        for row in rows if int(row["budget"]) == 8
    ]


def analyze() -> None:
    assert_frozen()
    if run_state() != "RUN_COMPLETE":
        raise RuntimeError(f"analysis requires RUN_COMPLETE state, got {run_state()}")
    tables = ARTIFACTS / "tables"
    aggregation_stats = _bootstrap_aggregation()
    generation_stats, risk_rows = _bootstrap_generation_bundle()
    try:
        scalar_rows = _build_figure_data(risk_rows)
    except Exception as exc:
        issue("analysis.figure_data", exc)
        raise
    statistics = aggregation_stats + generation_stats
    _holm(statistics)
    audit = ARTIFACTS / "reports" / "main_noise_00_rule_audit.jsonl"
    if audit.exists():
        _write_csv(tables / "table1_rules.csv", _rule_table(audit))
    aggregation = ARTIFACTS / "reports" / "main_noise_00_aggregation.jsonl"
    if aggregation.exists():
        _write_csv(tables / "table2_aggregation.csv", _macro_aggregation(aggregation))
    ablation = ARTIFACTS / "reports" / "main_noise_00_temperature_ablation.jsonl"
    if not ablation.exists():
        raise RuntimeError("missing clean-main temperature ablation report")
    _write_csv(
        tables / "table2b_temperature_ablation.csv",
        _temperature_ablation_table(ablation),
    )
    if scalar_rows:
        _write_csv(tables / "table3_generation.csv", _reporting_generation_table(scalar_rows))
        _write_csv(tables / "table3b_pass_at_5_secondary.csv", _pass_at_five())
    mixed = ARTIFACTS / "results" / "main_mixed_noise_00_generation_summary.jsonl"
    if mixed.exists():
        _write_csv(tables / "table5_mixed_hard_weak.csv", _mixed_table(mixed))
    if scalar_rows:
        _write_csv(tables / "table4_noise.csv", _reporting_noise_table(scalar_rows))
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
        _render_figures()
    except Exception as exc:
        issue("analysis.figure_render", exc)
        raise
    set_run_state("ANALYZED")
    set_run_state("READY_TO_ARCHIVE")
