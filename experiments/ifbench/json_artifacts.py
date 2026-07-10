"""Strict JSON helpers for experiment artifacts."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Iterable


NEG_INF_SENTINEL = "-Infinity"
POS_INF_SENTINEL = "Infinity"


def strict_json_value(value: Any) -> Any:
    if isinstance(value, float):
        if math.isnan(value):
            raise ValueError("NaN is not supported in experiment JSON artifacts")
        if math.isinf(value):
            return NEG_INF_SENTINEL if value < 0 else POS_INF_SENTINEL
        return value
    if isinstance(value, dict):
        return {key: strict_json_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [strict_json_value(item) for item in value]
    if isinstance(value, tuple):
        return [strict_json_value(item) for item in value]
    return value


def strict_json_dumps(value: Any, **kwargs: Any) -> str:
    return json.dumps(strict_json_value(value), allow_nan=False, **kwargs)


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(strict_json_dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")
