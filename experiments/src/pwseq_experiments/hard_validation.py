from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .common import EXPERIMENTS, REPO, python_env, read_jsonl, write_jsonl


def _run_native_ere(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "input.jsonl"
        output = Path(directory) / "output.jsonl"
        write_jsonl(source, rows)
        subprocess.run(
            ["racket", str(EXPERIMENTS / "racket" / "validate_hard.rkt"),
             "--input", str(source), "--output", str(output)],
            cwd=REPO, env=python_env(), check=True,
        )
        return read_jsonl(output)


def ere_compiles_many(patterns: list[str]) -> list[bool]:
    """Compile EREs with the same native path used by the library."""
    records = _run_native_ere([
        {"hard_spec": {"kind": "ere", "pattern": pattern}, "text": ""}
        for pattern in patterns
    ])
    return ["error" not in record for record in records]


def hard_accepts(hard_spec: dict[str, Any], text: str, token_count: int | None = None) -> bool:
    return hard_accepts_many([(hard_spec, text, token_count)])[0]


def hard_accepts_many(items: list[tuple[dict[str, Any], str, int | None]]) -> list[bool]:
    answers: list[bool | None] = [None] * len(items)
    racket_rows: list[dict[str, Any]] = []
    racket_indices: list[int] = []
    for index, (hard_spec, text, token_count) in enumerate(items):
        kind = hard_spec["kind"]
        if kind == "literal":
            answers[index] = text == hard_spec["value"]
        elif kind == "choice":
            answers[index] = text in hard_spec["values"]
        elif kind == "text":
            answers[index] = token_count is None or token_count <= int(hard_spec["max_tokens"])
        elif kind == "ere":
            racket_indices.append(index)
            racket_rows.append({"hard_spec": hard_spec, "text": text})
        else:
            raise ValueError(f"unknown hard kind: {kind}")
    if racket_rows:
        records = _run_native_ere(racket_rows)
        for index, record in zip(racket_indices, records, strict=True):
            if "error" in record:
                raise RuntimeError(record["error"])
            answers[index] = bool(record["valid"])
    return [bool(answer) for answer in answers]
