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


def ece(y: np.ndarray, probability: np.ndarray, bins: int = 15) -> float:
    order = np.argsort(probability, kind="stable")
    total = len(y)
    value = 0.0
    for indices in np.array_split(order, min(bins, total)):
        if len(indices):
            value += len(indices) / total * abs(float(probability[indices].mean() - y[indices].mean()))
    return value


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
    found = [row for row in rows if row["outcome"] != "NOT_FOUND"]
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
            if found[next_index]["outcome"] == "FOUND_OK":
                ok += 1
            else:
                wrong += 1
            next_index += 1
        curve.append({
            "coverage": (ok + wrong) / total,
            "risk": wrong / (ok + wrong),
            "solve_rate": ok / total,
        })
        index = next_index
    return curve


def aurc(curve: list[dict[str, float]]) -> float:
    return float(np.trapezoid(
        [point["risk"] for point in curve],
        [point["coverage"] for point in curve],
    ))


def safe_solve(curve: list[dict[str, float]], target: float) -> float:
    return max((point["solve_rate"] for point in curve if point["risk"] <= target), default=0.0)
