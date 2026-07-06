#!/usr/bin/env python3
"""Soft IFBench baseline methods over a candidate stream."""

from __future__ import annotations

import math
import re
from dataclasses import asdict, dataclass
from typing import Callable, Iterable, Sequence

from experiments.ifbench.outcomes import Candidate


REAL_METHODS = {
    "vanilla",
    "best_of_n_lm",
    "weak_posthoc_rerank",
    "weak_rejection",
    "ours_soft_decoding",
    "ours_hybrid_decoding",
}
ORACLE_METHOD = "oracle_verifier_selection"


@dataclass(frozen=True)
class MethodResult:
    example_id: str
    method: str
    candidate_id: int | None
    text: str | None
    lm_logprob: float | None
    weak_score: float | None
    total_score: float | None
    returned: bool
    return_policy: str
    hybrid_fallback: bool = False

    def to_json(self) -> dict:
        return asdict(self)


def policy_label(return_policy) -> str:
    if return_policy == "always":
        return "always"
    if isinstance(return_policy, tuple) and return_policy[0] == "min_score":
        return f"min_score:{return_policy[1]}"
    if isinstance(return_policy, tuple) and return_policy[0] == "risk_target":
        return f"risk_target:{return_policy[1]}"
    raise ValueError(f"unsupported return_policy: {return_policy!r}")


def threshold_for_policy(return_policy, default_threshold: float = -math.inf) -> float:
    if return_policy == "always":
        return -math.inf
    if isinstance(return_policy, tuple) and return_policy[0] == "min_score":
        return float(return_policy[1])
    if isinstance(return_policy, tuple) and return_policy[0] == "risk_target":
        _, epsilon, dev_scores = return_policy
        return risk_threshold(float(epsilon), dev_scores)
    raise ValueError(f"unsupported return_policy: {return_policy!r}")


def risk_threshold(epsilon: float, dev_scores: Sequence[tuple[float, bool]]) -> float:
    if not dev_scores:
        return math.inf
    thresholds = sorted({score for score, _ in dev_scores}, reverse=True)
    best = math.inf
    for threshold in thresholds:
        returned = [(score, ok) for score, ok in dev_scores if score >= threshold]
        if not returned:
            continue
        wrong_rate = sum(1 for _, ok in returned if not ok) / len(returned)
        if wrong_rate <= epsilon:
            best = threshold
    return best


def weak_score(text: str, rules: Sequence[dict]) -> float:
    score = 0.0
    for rule in rules:
        if rule_fires(rule, text):
            if rule["kind"] == "ban":
                return float("-inf")
            score += float(rule["weight"])
    return score


def rule_fires(rule: dict, text: str) -> bool:
    pattern = rule["pattern"]
    if rule["pattern_type"] == "literal":
        return pattern in text
    if rule["pattern_type"] != "regex":
        return False
    flags = 0
    if "(?i)" in pattern:
        flags |= re.IGNORECASE
        pattern = pattern.replace("(?i)", "")
    try:
        return bool(re.search(pattern, text, flags))
    except re.error:
        return False


def result_from_candidate(method: str, candidate: Candidate | None, score: float | None, return_policy, *, hybrid_fallback: bool = False, beta: float = 1.0) -> MethodResult:
    if candidate is None:
        return MethodResult(None if False else "", method, None, None, None, score, None, False, policy_label(return_policy), hybrid_fallback)
    total = candidate.lm_logprob + beta * (score or 0.0)
    return MethodResult(candidate.example_id, method, candidate.candidate_id, candidate.text, candidate.lm_logprob, score, total, True, policy_label(return_policy), hybrid_fallback)


def not_found(method: str, example_id: str, return_policy, *, hybrid_fallback: bool = False) -> MethodResult:
    return MethodResult(example_id, method, None, None, None, None, None, False, policy_label(return_policy), hybrid_fallback)


def maybe_return(method: str, candidate: Candidate | None, score: float | None, return_policy, *, example_id: str, hybrid_fallback: bool = False, beta: float = 1.0) -> MethodResult:
    if candidate is None:
        return not_found(method, example_id, return_policy, hybrid_fallback=hybrid_fallback)
    threshold = threshold_for_policy(return_policy)
    if score is not None and score < threshold:
        return not_found(method, candidate.example_id, return_policy, hybrid_fallback=hybrid_fallback)
    return result_from_candidate(method, candidate, score, return_policy, hybrid_fallback=hybrid_fallback, beta=beta)


def vanilla(candidates: Sequence[Candidate], return_policy="always", **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    return maybe_return("vanilla", candidates[0] if candidates else None, None, return_policy, example_id=example_id)


def best_of_n_lm(candidates: Sequence[Candidate], return_policy="always", **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    candidate = max(candidates, key=lambda item: item.lm_logprob, default=None)
    return maybe_return("best_of_n_lm", candidate, None, return_policy, example_id=example_id)


def weak_posthoc_rerank(candidates: Sequence[Candidate], rules: Sequence[dict], return_policy="always", **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    scored = [(weak_score(candidate.text, rules), candidate) for candidate in candidates]
    if not scored:
        return not_found("weak_posthoc_rerank", example_id, return_policy)
    score, candidate = max(scored, key=lambda item: (item[0], item[1].lm_logprob))
    return maybe_return("weak_posthoc_rerank", candidate, score, return_policy, example_id=example_id)


def weak_rejection(candidates: Sequence[Candidate], rules: Sequence[dict], return_policy=("min_score", 0.0), **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    threshold = threshold_for_policy(return_policy, 0.0)
    for candidate in candidates:
        score = weak_score(candidate.text, rules)
        if score >= threshold:
            return result_from_candidate("weak_rejection", candidate, score, return_policy)
    return not_found("weak_rejection", example_id, return_policy)


def ours_soft_decoding(candidates: Sequence[Candidate], rules: Sequence[dict], return_policy="always", beta: float = 1.0, **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    scored = [(candidate.lm_logprob + beta * weak_score(candidate.text, rules), weak_score(candidate.text, rules), candidate) for candidate in candidates]
    if not scored:
        return not_found("ours_soft_decoding", example_id, return_policy)
    _, score, candidate = max(scored, key=lambda item: item[0])
    return maybe_return("ours_soft_decoding", candidate, score, return_policy, example_id=example_id, beta=beta)


def ours_hybrid_decoding(candidates: Sequence[Candidate], rules: Sequence[dict], return_policy="always", hard_skeleton: dict | None = None, beta: float = 1.0, **_) -> MethodResult:
    result = ours_soft_decoding(candidates, rules, return_policy=return_policy, beta=beta)
    fallback = hard_skeleton is None
    return MethodResult(**{**result.to_json(), "method": "ours_hybrid_decoding", "hybrid_fallback": fallback})


def oracle_verifier_selection(candidates: Sequence[Candidate], official_verifier: Callable[[str], bool], return_policy="always", **_) -> MethodResult:
    example_id = candidates[0].example_id if candidates else ""
    for candidate in candidates:
        if official_verifier(candidate.text):
            return result_from_candidate(ORACLE_METHOD, candidate, None, return_policy)
    return not_found(ORACLE_METHOD, example_id, return_policy)


METHODS = {
    "vanilla": vanilla,
    "best_of_n_lm": best_of_n_lm,
    "weak_posthoc_rerank": weak_posthoc_rerank,
    "weak_rejection": weak_rejection,
    "ours_soft_decoding": ours_soft_decoding,
    "ours_hybrid_decoding": ours_hybrid_decoding,
    "oracle_verifier_selection": oracle_verifier_selection,
}


def run_method(name: str, candidates: Sequence[Candidate], *, rules: Sequence[dict] = (), return_policy="always", official_verifier: Callable[[str], bool] | None = None, **kwargs) -> MethodResult:
    if name not in METHODS:
        raise ValueError(f"unknown method: {name}")
    if name != ORACLE_METHOD and official_verifier is not None:
        raise ValueError("official verifier may only be passed to oracle_verifier_selection")
    if name == ORACLE_METHOD:
        if official_verifier is None:
            raise ValueError("oracle_verifier_selection requires official_verifier")
        return METHODS[name](candidates, official_verifier=official_verifier, return_policy=return_policy, **kwargs)
    return METHODS[name](candidates, rules=rules, return_policy=return_policy, **kwargs)
