from __future__ import annotations

import math
from typing import Any, Iterable

import numpy as np


def average_precision(y: np.ndarray, score: np.ndarray) -> float:
    order = np.argsort(-score, kind="stable")
    labels = y[order]
    positives = int(labels.sum())
    if positives == 0:
        return float("nan")
    precision = np.cumsum(labels) / np.arange(1, len(labels) + 1)
    return float((precision * labels).sum() / positives)


def auroc(y: np.ndarray, score: np.ndarray) -> float:
    positives = int(y.sum())
    negatives = len(y) - positives
    if positives == 0 or negatives == 0:
        return float("nan")
    order = np.argsort(score, kind="stable")
    ranks = np.empty(len(score), dtype=float)
    sorted_scores = score[order]
    start = 0
    while start < len(score):
        end = start + 1
        while end < len(score) and sorted_scores[end] == sorted_scores[start]:
            end += 1
        ranks[order[start:end]] = (start + 1 + end) / 2
        start = end
    return float((ranks[y == 1].sum() - positives * (positives + 1) / 2) / (positives * negatives))


def nll(y: np.ndarray, probability: np.ndarray) -> float:
    p = np.clip(probability, 1e-6, 1 - 1e-6)
    return float(-(y * np.log(p) + (1 - y) * np.log(1 - p)).mean())


def brier(y: np.ndarray, probability: np.ndarray) -> float:
    return float(np.mean((probability - y) ** 2))


def calibration_bins(y: np.ndarray, probability: np.ndarray, bins: int = 15) -> list[dict[str, float | int]]:
    order = np.argsort(probability, kind="stable")
    return [{
        "count": int(len(indices)),
        "mean_probability": float(probability[indices].mean()),
        "empirical_rate": float(y[indices].mean()),
    } for indices in np.array_split(order, min(bins, len(y))) if len(indices)]


def ece(y: np.ndarray, probability: np.ndarray, bins: int = 15) -> float:
    groups = calibration_bins(y, probability, bins)
    total = sum(int(group["count"]) for group in groups)
    return sum(
        int(group["count"]) / total
        * abs(float(group["mean_probability"]) - float(group["empirical_rate"]))
        for group in groups
    ) if total else float("nan")


def classification_metrics(
    labels: Iterable[bool], probabilities: Iterable[float], *, bins: int = 15,
) -> dict[str, float]:
    y = np.asarray(list(labels), dtype=int)
    p = np.asarray(list(probabilities), dtype=float)
    return {
        "auprc": average_precision(y, p),
        "auroc": auroc(y, p),
        "nll": nll(y, p),
        "brier": brier(y, p),
        "ece": ece(y, p, bins=bins),
    }


def equal_probability(labels: list[int]) -> float:
    return 1.0 / (1.0 + math.exp(-sum(labels)))


def majority_probability(labels: list[int]) -> float:
    positive = sum(value > 0 for value in labels)
    negative = sum(value < 0 for value in labels)
    return (positive + 1.0) / (positive + negative + 2.0)


def effective_rank(matrix: np.ndarray) -> float:
    if matrix.size == 0:
        return 0.0
    centered = matrix - matrix.mean(axis=0, keepdims=True)
    values = np.linalg.svd(centered, compute_uv=False) ** 2
    total = values.sum()
    if total <= 0:
        return 0.0
    weights = values[values > 0] / total
    return float(np.exp(-(weights * np.log(weights)).sum()))


def selective_curve(rows: list[dict[str, Any]], confidence_key: str = "confidence") -> list[dict[str, float]]:
    found = [
        row for row in rows
        if float(row.get("return_weight", row["outcome"] != "NOT_FOUND")) > 0
    ]
    found.sort(key=lambda row: float(row[confidence_key]), reverse=True)
    curve = [{"coverage": 0.0, "risk": 0.0, "solve_rate": 0.0}]
    wrong = ok = 0
    total = len(rows)
    index = 0
    while index < len(found):
        confidence = float(found[index][confidence_key])
        next_index = index
        while (
            next_index < len(found)
            and float(found[next_index][confidence_key]) == confidence
        ):
            row = found[next_index]
            ok += float(row.get("ok_weight", row["outcome"] == "FOUND_OK"))
            wrong += float(row.get("wrong_weight", row["outcome"] == "FOUND_WRONG"))
            next_index += 1
        curve.append({
            "coverage": (ok + wrong) / total,
            "risk": wrong / (ok + wrong),
            "solve_rate": ok / total,
        })
        index = next_index
    return curve


def max_coverage(curve: list[dict[str, float]]) -> float:
    return max((point["coverage"] for point in curve), default=0.0)


def _curve_at(curve: list[dict[str, float]], coverage: float) -> float | None:
    if coverage < 0 or coverage > max_coverage(curve):
        return None
    for point in curve:
        if point["coverage"] >= coverage:
            return point["risk"]
    return None


def normalized_partial_aurc(curve: list[dict[str, float]], limit: float) -> float | None:
    if limit <= 0 or max_coverage(curve) < limit:
        return None
    points = [(point["coverage"], point["risk"]) for point in curve if point["coverage"] < limit]
    risk = _curve_at(curve, limit)
    if risk is None:
        return None
    points.append((limit, risk))
    return float(np.trapezoid([value for _, value in points], [x for x, _ in points]) / limit)


def common_coverage_metrics(
    curves: dict[str, list[dict[str, float]]], targets: tuple[float, ...] = (.25, .50, .75),
) -> dict[str, dict[str, float | None]]:
    limit = min((max_coverage(curve) for curve in curves.values()), default=0.0)
    return {method: {
        "max_coverage": max_coverage(curve),
        "common_coverage": limit,
        "normalized_partial_aurc": normalized_partial_aurc(curve, limit),
        **{f"risk_at_{int(target * 100):02d}": _curve_at(curve, target) for target in targets},
    } for method, curve in curves.items()}


def operating_metrics(rows: list[dict[str, Any]]) -> dict[str, float | int | None]:
    ok = sum(row["outcome"] == "FOUND_OK" for row in rows)
    wrong = sum(row["outcome"] == "FOUND_WRONG" for row in rows)
    returned = ok + wrong
    total = len(rows)
    return {
        "found_ok": ok, "found_wrong": wrong, "not_found": total - returned,
        "solve_rate": ok / total if total else 0.0,
        "coverage": returned / total if total else 0.0,
        "risk": wrong / returned if returned else None,
    }


def oracle_safe_solve(curve: list[dict[str, float]], target: float) -> float:
    """Test-label optimized oracle; appendix diagnostics only."""
    return max((point["solve_rate"] for point in curve if point["risk"] <= target), default=0.0)


def corrected_bootstrap_p(values: Iterable[float]) -> float:
    array = np.asarray(list(values), dtype=float)
    repetitions = len(array)
    if not repetitions:
        return float("nan")
    tail = min(int(np.sum(array <= 0)), int(np.sum(array >= 0)))
    return float(min(1.0, 2.0 * (tail + 1) / (repetitions + 1)))
