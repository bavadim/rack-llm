#!/usr/bin/env python3
"""Unit tests for soft methods and outcomes."""

from __future__ import annotations

import inspect
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from experiments.ifbench.outcomes import Candidate, Outcome, classify
from experiments.ifbench.soft_methods import (
    ORACLE_METHOD,
    REAL_METHODS,
    oracle_verifier_selection,
    run_method,
    weak_rejection,
)


def candidates() -> list[Candidate]:
    return [
        Candidate("ex", 0, "bad", lm_logprob=-1.0),
        Candidate("ex", 1, "good", lm_logprob=-2.0),
    ]


def test_found_ok() -> None:
    assert classify(Candidate("ex", 0, "ok"), lambda text: text == "ok") == Outcome.FOUND_OK


def test_found_wrong() -> None:
    assert classify(Candidate("ex", 0, "bad"), lambda text: False) == Outcome.FOUND_WRONG


def test_not_found() -> None:
    assert classify(None, lambda text: True) == Outcome.NOT_FOUND


def test_weak_rejection_threshold() -> None:
    rules = [{"kind": "rank", "weight": 1.0, "pattern_type": "literal", "pattern": "needle"}]
    result = weak_rejection(candidates(), rules, return_policy=("min_score", 2.0))
    assert not result.returned
    assert result.method == "weak_rejection"


def test_oracle_not_used_by_real_methods() -> None:
    for method in REAL_METHODS:
        try:
            run_method(method, candidates(), official_verifier=lambda text: text == "good")
        except ValueError as error:
            assert "official verifier" in str(error)
        else:
            raise AssertionError(f"{method} accepted official verifier")
    result = run_method(ORACLE_METHOD, candidates(), official_verifier=lambda text: text == "good")
    assert result.returned
    assert result.candidate_id == 1
    source = Path(inspect.getsourcefile(oracle_verifier_selection)).read_text(encoding="utf-8")
    assert "official_verifier(candidate.text)" in source


def main() -> int:
    tests = [
        test_found_ok,
        test_found_wrong,
        test_not_found,
        test_weak_rejection_threshold,
        test_oracle_not_used_by_real_methods,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
