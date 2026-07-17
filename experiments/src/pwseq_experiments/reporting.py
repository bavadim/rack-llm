from __future__ import annotations

from collections import defaultdict
from typing import Any, Callable

import numpy as np


def prompt_generation_records(
    rows: list[dict[str, Any]],
    *,
    expected_seeds: set[int],
    decisions: dict[tuple[str, int], dict[str, Any]] | None = None,
    accepts: Callable[[dict[str, Any], dict[str, Any]], bool] | None = None,
) -> list[dict[str, Any]]:
    """Collapse a complete prompt x seed cohort to one stochastic prompt record."""
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(str(row["method"]), int(row["budget"]), str(row["prompt_id"]))].append(row)
    output = []
    for (method, budget, prompt_id), values in sorted(grouped.items()):
        seeds = [int(row["seed"]) for row in values]
        if len(seeds) != len(set(seeds)) or set(seeds) != expected_seeds:
            raise RuntimeError(
                f"invalid seed cohort: {method}/{budget}/{prompt_id}: {seeds}"
            )
        families = {str(row["family"]) for row in values}
        if len(families) != 1:
            raise RuntimeError(f"inconsistent family for {method}/{budget}/{prompt_id}")
        decision = None
        if decisions is not None:
            decision = decisions.get((method, budget))
            if decision is None:
                raise RuntimeError(f"missing dev threshold: {method}/{budget}")
            if accepts is None:
                raise RuntimeError("threshold decisions require an acceptance function")
        outcomes = []
        for row in values:
            outcome = str(row["outcome"])
            if (
                decision is not None and outcome != "NOT_FOUND"
                and not accepts(row, decision)
            ):
                outcome = "NOT_FOUND"
            outcomes.append(outcome)
        returned_confidence = [
            float(row["confidence"])
            for row, outcome in zip(values, outcomes, strict=True)
            if outcome != "NOT_FOUND"
        ]
        output.append({
            "method": method,
            "budget": budget,
            "prompt_id": prompt_id,
            "family": families.pop(),
            "outcome": "PROMPT_MEAN",
            # NOT_FOUND rows use sentinel confidences whose scale differs by
            # method (for example 0 versus a negative LM log-probability).
            # Rank prompts only by confidence of seeds that actually return.
            "confidence": (
                float(np.mean(returned_confidence)) if returned_confidence else 0.0
            ),
            "ok_weight": float(np.mean([value == "FOUND_OK" for value in outcomes])),
            "wrong_weight": float(np.mean([value == "FOUND_WRONG" for value in outcomes])),
            "return_weight": float(np.mean([value != "NOT_FOUND" for value in outcomes])),
            "model_draws": float(np.mean([float(row.get("model_draws", 0)) for row in values])),
        })
    return output


def _point_macro(records: list[dict[str, Any]]) -> dict[str, float | int | None]:
    by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in records:
        by_family[str(row["family"])].append(row)
    if not by_family:
        raise RuntimeError("cannot summarize an empty prompt set")
    values: dict[str, list[float]] = defaultdict(list)
    for items in by_family.values():
        ok = np.asarray([row["ok_weight"] for row in items], dtype=float)
        wrong = np.asarray([row["wrong_weight"] for row in items], dtype=float)
        returned = np.asarray([row["return_weight"] for row in items], dtype=float)
        draws = np.asarray([row["model_draws"] for row in items], dtype=float)
        values["solve_rate"].append(float(ok.mean()))
        values["coverage"].append(float(returned.mean()))
        values["found_wrong_rate"].append(float(wrong.mean()))
        values["not_found_rate"].append(float(1.0 - returned.mean()))
        values["mean_model_tokens"].append(float(draws.mean()))
        if returned.sum() > 0:
            values["risk"].append(float(wrong.sum() / returned.sum()))
        if ok.sum() > 0:
            values["tokens_per_ok"].append(float(draws.sum() / ok.sum()))
    result: dict[str, float | int | None] = {
        key: float(np.mean(items)) if items else None
        for key, items in values.items()
    }
    result.update({"families": len(by_family), "prompts": len(records)})
    return result


def _nanmean_columns(values: np.ndarray) -> np.ndarray:
    counts = np.sum(np.isfinite(values), axis=0)
    totals = np.nansum(values, axis=0)
    return np.divide(
        totals, counts, out=np.full(totals.shape, np.nan), where=counts > 0,
    )


def generation_scalar_data(
    records: list[dict[str, Any]],
    *,
    repetitions: int,
    confidence: float,
    seed: int,
) -> list[dict[str, Any]]:
    """Prompt-stratified macro estimates and percentile intervals."""
    grids: dict[tuple[float, int], dict[str, set[tuple[str, str]]]] = defaultdict(
        lambda: defaultdict(set)
    )
    for row in records:
        grids[(float(row["noise"]), int(row["budget"]))][str(row["method"])].add(
            (str(row["family"]), str(row["prompt_id"]))
        )
    for (noise, budget), methods in grids.items():
        reference_method = sorted(methods)[0]
        reference = methods[reference_method]
        for method, prompts in methods.items():
            if prompts != reference:
                raise RuntimeError(
                    f"unpaired prompt grid: noise={noise}/budget={budget}/{method}"
                )
    groups: dict[tuple[float, str, int], list[dict[str, Any]]] = defaultdict(list)
    for row in records:
        groups[(float(row["noise"]), str(row["method"]), int(row["budget"]))].append(row)
    tail = (1.0 - confidence) / 2.0
    rng = np.random.default_rng(seed)
    output = []
    metric_names = (
        "solve_rate", "coverage", "found_wrong_rate", "not_found_rate",
        "mean_model_tokens", "risk", "tokens_per_ok",
    )
    for (noise, method, budget), items in sorted(groups.items()):
        point = _point_macro(items)
        by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for row in items:
            by_family[str(row["family"])].append(row)
        samples: dict[str, list[np.ndarray]] = defaultdict(list)
        for family in sorted(by_family):
            family_rows = sorted(by_family[family], key=lambda row: str(row["prompt_id"]))
            if len({row["prompt_id"] for row in family_rows}) != len(family_rows):
                raise RuntimeError(f"duplicate prompt record: {noise}/{method}/{budget}/{family}")
            size = len(family_rows)
            indices = rng.integers(0, size, size=(repetitions, size))
            ok = np.asarray([row["ok_weight"] for row in family_rows], dtype=float)[indices]
            wrong = np.asarray([row["wrong_weight"] for row in family_rows], dtype=float)[indices]
            returned = np.asarray([row["return_weight"] for row in family_rows], dtype=float)[indices]
            draws = np.asarray([row["model_draws"] for row in family_rows], dtype=float)[indices]
            samples["solve_rate"].append(ok.mean(axis=1))
            samples["coverage"].append(returned.mean(axis=1))
            samples["found_wrong_rate"].append(wrong.mean(axis=1))
            samples["not_found_rate"].append(1.0 - returned.mean(axis=1))
            samples["mean_model_tokens"].append(draws.mean(axis=1))
            returned_sum = returned.sum(axis=1)
            samples["risk"].append(np.divide(
                wrong.sum(axis=1), returned_sum,
                out=np.full(repetitions, np.nan), where=returned_sum > 0,
            ))
            ok_sum = ok.sum(axis=1)
            samples["tokens_per_ok"].append(np.divide(
                draws.sum(axis=1), ok_sum,
                out=np.full(repetitions, np.nan), where=ok_sum > 0,
            ))
        row: dict[str, Any] = {
            "noise": noise, "method": method, "budget": budget,
            "families": point["families"], "prompts": point["prompts"],
            "bootstrap_repetitions": repetitions, "confidence_level": confidence,
        }
        for metric in metric_names:
            distribution = _nanmean_columns(np.vstack(samples[metric]))
            finite = distribution[np.isfinite(distribution)]
            row[metric] = point.get(metric)
            row[f"{metric}_ci_low"] = (
                float(np.quantile(finite, tail)) if len(finite) else None
            )
            row[f"{metric}_ci_high"] = (
                float(np.quantile(finite, 1.0 - tail)) if len(finite) else None
            )
            row[f"{metric}_support"] = int(len(finite))
        output.append(row)
    return output


def reliability_data(
    score_rows: list[dict[str, Any]],
    gold: dict[str, int],
    *,
    bins: int,
    repetitions: int,
    confidence: float,
    seed: int,
) -> list[dict[str, Any]]:
    """Fixed full-data quantile bins with prompt-cluster bootstrap intervals."""
    rows = [row for row in score_rows if row.get("candidate_id") in gold]
    if not rows:
        raise RuntimeError("cannot build reliability data without scored candidates")
    probability = np.asarray([float(row["posterior"]) for row in rows])
    edges = np.quantile(probability, np.linspace(0.0, 1.0, bins + 1))
    assignments = np.searchsorted(edges[1:-1], probability, side="right")
    contributions: dict[str, dict[str, np.ndarray]] = defaultdict(dict)
    for index, row in enumerate(rows):
        prompt = str(row["prompt_id"])
        family = str(row["family"])
        key = f"{family}\0{prompt}"
        if key not in contributions[family]:
            contributions[family][key] = np.zeros((bins, 3), dtype=float)
        slot = int(assignments[index])
        contributions[family][key][slot] += (
            1.0, probability[index], float(gold[row["candidate_id"]]),
        )
    full = np.zeros((bins, 3), dtype=float)
    for prompts in contributions.values():
        for value in prompts.values():
            full += value
    rng = np.random.default_rng(seed)
    bootstrap = np.zeros((repetitions, bins, 3), dtype=float)
    for family in sorted(contributions):
        matrix = np.stack([
            contributions[family][prompt]
            for prompt in sorted(contributions[family])
        ])
        size = len(matrix)
        indices = rng.integers(0, size, size=(repetitions, size))
        bootstrap += matrix[indices].sum(axis=1)
    counts = bootstrap[:, :, 0]
    mean_probability = np.divide(
        bootstrap[:, :, 1], counts,
        out=np.full((repetitions, bins), np.nan), where=counts > 0,
    )
    empirical_rate = np.divide(
        bootstrap[:, :, 2], counts,
        out=np.full((repetitions, bins), np.nan), where=counts > 0,
    )
    tail = (1.0 - confidence) / 2.0
    output = []
    for slot in range(bins):
        if full[slot, 0] == 0:
            continue
        p_values = mean_probability[:, slot]
        y_values = empirical_rate[:, slot]
        p_values = p_values[np.isfinite(p_values)]
        y_values = y_values[np.isfinite(y_values)]
        if not len(p_values) or not len(y_values):
            raise RuntimeError(f"zero bootstrap support for reliability bin {slot}")
        output.append({
            "bin": slot,
            "lower_bound": float(edges[slot]),
            "upper_bound": float(edges[slot + 1]),
            "count": int(full[slot, 0]),
            "mean_probability": float(full[slot, 1] / full[slot, 0]),
            "mean_probability_ci_low": float(np.quantile(p_values, tail)),
            "mean_probability_ci_high": float(np.quantile(p_values, 1.0 - tail)),
            "empirical_rate": float(full[slot, 2] / full[slot, 0]),
            "empirical_rate_ci_low": float(np.quantile(y_values, tail)),
            "empirical_rate_ci_high": float(np.quantile(y_values, 1.0 - tail)),
            "bootstrap_repetitions": repetitions,
            "bootstrap_support": int(len(y_values)),
            "confidence_level": confidence,
        })
    return output
