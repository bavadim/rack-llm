"""Compatibility import for Experiment 012 strict JSON helpers."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from experiments.ifbench.json_artifacts import (
    NEG_INF_SENTINEL,
    POS_INF_SENTINEL,
    strict_json_dumps,
    strict_json_value,
    write_jsonl,
)

__all__ = [
    "NEG_INF_SENTINEL",
    "POS_INF_SENTINEL",
    "strict_json_dumps",
    "strict_json_value",
    "write_jsonl",
]
