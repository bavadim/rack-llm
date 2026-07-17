"""Explicit, independent FUSE reimplementation for discrete weak sources.

This is not official FUSE code.  It follows the zero-label moment/triplet
pipeline described in the paper and records that provenance in every model.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any

import numpy as np
from scipy.optimize import least_squares, minimize


EPS = 1e-6


@dataclass
class FuseModel:
    status: str
    thresholds: list[float]
    kept_sources: list[int]
    class_balance: float
    accuracies: list[float]
    logistic_weights: list[float]
    logistic_intercept: float
    provenance: str = "independent_reimplementation_of_FUSE_paper"
    official_implementation: bool = False
    reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "FuseModel":
        return cls(**value)


def _binarize(x: np.ndarray, thresholds: np.ndarray) -> np.ndarray:
    return (x > thresholds[None, :]).astype(float)


def _moments(binary: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    centered = binary - binary.mean(axis=0, keepdims=True)
    covariance = centered.T @ centered / len(centered)
    third = np.einsum("ni,nj,nk->ijk", centered, centered, centered) / len(centered)
    return covariance, third


def _tci_objective(binary: np.ndarray) -> float:
    covariance, third = _moments(binary)
    m = binary.shape[1]
    values: list[float] = []
    for i in range(m):
        for j in range(i + 1, m):
            denominator = covariance[i, j]
            if abs(denominator) < EPS:
                continue
            ratios = [
                third[i, j, k] / denominator
                for k in range(m) if k not in {i, j}
            ]
            if len(ratios) >= 2:
                values.append(float(np.var(ratios)))
    return float(np.mean(values)) if values else float("inf")


def _select_thresholds(x: np.ndarray) -> np.ndarray:
    choices = np.asarray([-0.5, 0.5])
    best_thresholds: np.ndarray | None = None
    best_score = float("inf")
    # Deterministic coordinate descent from both uniform initializations.
    for initial in choices:
        thresholds = np.full(x.shape[1], initial)
        for _ in range(8):
            changed = False
            for source in range(x.shape[1]):
                candidates = []
                for threshold in choices:
                    trial = thresholds.copy()
                    trial[source] = threshold
                    candidates.append((_tci_objective(_binarize(x, trial)), threshold))
                _, selected = min(candidates, key=lambda item: (item[0], item[1]))
                if selected != thresholds[source]:
                    thresholds[source] = selected
                    changed = True
            if not changed:
                break
        score = _tci_objective(_binarize(x, thresholds))
        if (score, thresholds.tolist()) < (
            best_score,
            best_thresholds.tolist() if best_thresholds is not None else [float("inf")],
        ):
            best_score, best_thresholds = score, thresholds.copy()
    assert best_thresholds is not None
    return best_thresholds


def _estimate_moments(binary: np.ndarray) -> tuple[float, np.ndarray]:
    covariance, third = _moments(binary)
    m = binary.shape[1]
    pairs = [(i, j) for i in range(m) for j in range(i + 1, m)]
    if len(pairs) < 3:
        raise ValueError("FUSE requires at least three sources")

    def residual(log_abs_u: np.ndarray) -> np.ndarray:
        u = np.exp(log_abs_u)
        return np.asarray([
            u[i] * u[j] - max(EPS, abs(covariance[i, j]))
            for i, j in pairs
        ])

    solution = least_squares(residual, np.full(m, -1.0), max_nfev=5000)
    u = np.exp(solution.x)
    # Resolve source signs from covariance relative to the most connected source.
    anchor = int(np.argmax(np.sum(np.abs(covariance), axis=0)))
    signs = np.ones(m)
    for i in range(m):
        if i != anchor and covariance[anchor, i] < 0:
            signs[i] = -1
    u *= signs

    ratios = []
    for i in range(m):
        for j in range(i + 1, m):
            for k in range(j + 1, m):
                denominator = u[i] * u[j] * u[k]
                if abs(denominator) >= EPS:
                    ratios.append(third[i, j, k] / denominator)
    if not ratios:
        raise ValueError("FUSE third moment is unidentified")
    r = float(np.median(ratios))
    balance = float(np.clip(0.5 * (1.0 - r / np.sqrt(r * r + 4.0)), EPS, 1 - EPS))

    means = binary.mean(axis=0)
    scale = np.sqrt(balance * (1.0 - balance))
    delta = u / max(scale, EPS)
    sensitivity = np.clip(means + (1.0 - balance) * delta, EPS, 1 - EPS)
    false_positive = np.clip(means - balance * delta, EPS, 1 - EPS)
    accuracy = balance * sensitivity + (1.0 - balance) * (1.0 - false_positive)
    return balance, accuracy


def _triplet_soft_labels(binary: np.ndarray, balance: float, accuracy: np.ndarray) -> np.ndarray:
    m = binary.shape[1]
    if m < 3:
        raise ValueError("FUSE requires at least three retained sources")
    error = np.clip(1.0 - accuracy, EPS, 1 - EPS)
    logits = np.full(len(binary), np.log(balance / (1.0 - balance)))
    # Equation-13-style independent triplet posteriors, averaged over triplets.
    triplet_logits = []
    for i in range(m):
        for j in range(i + 1, m):
            for k in range(j + 1, m):
                value = np.full(len(binary), np.log(balance / (1.0 - balance)))
                for source in (i, j, k):
                    vote = binary[:, source]
                    weight = np.log(accuracy[source] / error[source])
                    value += (2.0 * vote - 1.0) * weight
                triplet_logits.append(value)
    if triplet_logits:
        logits = np.mean(np.asarray(triplet_logits), axis=0)
    return 1.0 / (1.0 + np.exp(-np.clip(logits, -40, 40)))


def _fit_soft_logistic(x: np.ndarray, soft_y: np.ndarray) -> tuple[np.ndarray, float]:
    def objective(parameters: np.ndarray) -> tuple[float, np.ndarray]:
        weights, intercept = parameters[:-1], parameters[-1]
        logits = x @ weights + intercept
        probability = 1.0 / (1.0 + np.exp(-np.clip(logits, -40, 40)))
        loss = -np.mean(
            soft_y * np.log(np.clip(probability, EPS, 1.0))
            + (1.0 - soft_y) * np.log(np.clip(1.0 - probability, EPS, 1.0))
        ) + 0.5 * np.dot(weights, weights) / len(x)
        error = probability - soft_y
        gradient = np.r_[x.T @ error / len(x) + weights / len(x), error.mean()]
        return float(loss), gradient

    result = minimize(
        lambda p: objective(p)[0],
        np.zeros(x.shape[1] + 1),
        jac=lambda p: objective(p)[1],
        method="L-BFGS-B",
    )
    if not result.success:
        raise ValueError(f"FUSE soft logistic failed: {result.message}")
    return result.x[:-1], float(result.x[-1])


def fit_fuse(labels: list[list[int]]) -> FuseModel:
    x = np.asarray(labels, dtype=float)
    if x.ndim != 2 or len(x) < 2 or x.shape[1] < 3:
        return FuseModel("BLOCKED", [], [], 0.5, [], [], 0.0, reason="insufficient_matrix")
    try:
        thresholds = _select_thresholds(x)
        binary = _binarize(x, thresholds)
        balance, accuracies = _estimate_moments(binary)
        kept = np.flatnonzero(accuracies >= 0.5).tolist()
        if len(kept) < 3:
            return FuseModel(
                "BLOCKED", thresholds.tolist(), kept, balance, accuracies.tolist(),
                [], 0.0, reason="fewer_than_three_sources_with_estimated_accuracy_ge_0.5",
            )
        retained = binary[:, kept]
        retained_accuracy = accuracies[kept]
        soft_y = _triplet_soft_labels(retained, balance, retained_accuracy)
        weights, intercept = _fit_soft_logistic(x[:, kept], soft_y)
        return FuseModel(
            "OK", thresholds.tolist(), kept, balance, accuracies.tolist(),
            weights.tolist(), intercept,
        )
    except Exception as exc:
        return FuseModel("BLOCKED", [], [], 0.5, [], [], 0.0, reason=str(exc))


def predict_fuse(model: FuseModel, labels: list[list[int]]) -> np.ndarray:
    if model.status != "OK":
        raise ValueError(model.reason or "FUSE model is blocked")
    x = np.asarray(labels, dtype=float)
    selected = x[:, model.kept_sources]
    logits = selected @ np.asarray(model.logistic_weights) + model.logistic_intercept
    return 1.0 / (1.0 + np.exp(-np.clip(logits, -40, 40)))
