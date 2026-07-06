#!/usr/bin/env python3
"""Common three-way outcomes for IFBench candidate streams."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Callable


class Outcome(str, Enum):
    FOUND_OK = "FOUND_OK"
    FOUND_WRONG = "FOUND_WRONG"
    NOT_FOUND = "NOT_FOUND"


@dataclass(frozen=True)
class Candidate:
    example_id: str
    candidate_id: int
    text: str
    lm_logprob: float = 0.0
    metadata: dict | None = None


def classify(candidate_or_none: Candidate | None, official_verifier: Callable[[str], bool]) -> Outcome:
    if candidate_or_none is None:
        return Outcome.NOT_FOUND
    if official_verifier(candidate_or_none.text):
        return Outcome.FOUND_OK
    return Outcome.FOUND_WRONG
