from __future__ import annotations

import importlib
import copy
import hashlib
import json
import sqlite3
import sys
from concurrent.futures import ProcessPoolExecutor
from typing import Any

from .common import CACHE

_EVALUATOR: Any | None = None
_EVALUATOR_FINGERPRINT: str | None = None


def load_evaluator() -> Any:
    global _EVALUATOR
    if _EVALUATOR is not None:
        return _EVALUATOR
    root = CACHE / "ifbench"
    if not root.exists():
        raise FileNotFoundError("pinned IFBench checkout is unavailable")
    root_text = str(root)
    if root_text not in sys.path:
        sys.path.insert(0, root_text)
    _EVALUATOR = importlib.import_module("evaluation_lib")
    return _EVALUATOR


def official_check(row: dict[str, Any], text: str, evaluator: Any) -> bool:
    example = evaluator.InputExample(
        key=row.get("key", row.get("source_key", row.get("id", 0))),
        instruction_id_list=list(row["instruction_id_list"]),
        prompt=row["prompt"],
        kwargs=copy.deepcopy(row["kwargs"]),
    )
    result = evaluator.test_instruction_following_strict(
        example, {row["prompt"]: text}
    )
    return bool(result.follow_all_instructions)


def _cache_key(row: dict[str, Any], text: str) -> str:
    global _EVALUATOR_FINGERPRINT
    if _EVALUATOR_FINGERPRINT is None:
        digest = hashlib.sha256()
        root = CACHE / "ifbench"
        for name in (
            "evaluation_lib.py", "instructions.py",
            "instructions_registry.py", "instructions_util.py",
        ):
            path = root / name
            digest.update(name.encode("utf-8"))
            digest.update(path.read_bytes())
        _EVALUATOR_FINGERPRINT = digest.hexdigest()
    payload = {
        "format": "ifbench-official-check-v1",
        "evaluator_fingerprint": _EVALUATOR_FINGERPRINT,
        "prompt": row["prompt"],
        "instruction_id_list": row["instruction_id_list"],
        "kwargs": row["kwargs"],
        "text": text,
    }
    encoded = json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _worker_check(item: tuple[dict[str, Any], str]) -> bool:
    row, text = item
    return official_check(row, text, load_evaluator())


def official_check_many(
    items: list[tuple[dict[str, Any], str]], *, workers: int = 1
) -> list[bool]:
    """Evaluate unique prompt/text pairs once and preserve input ordering."""
    if not items:
        return []
    cache_path = CACHE / "official_evaluator.sqlite3"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(cache_path)
    try:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS results "
            "(cache_key TEXT PRIMARY KEY, passed INTEGER NOT NULL)"
        )
        keys = [_cache_key(row, text) for row, text in items]
        unique: dict[str, tuple[dict[str, Any], str]] = {}
        for key, item in zip(keys, items, strict=True):
            unique.setdefault(key, item)
        cached: dict[str, bool] = {}
        key_list = list(unique)
        # Stay below SQLite's host-parameter limit while avoiding one query per
        # candidate.
        for start in range(0, len(key_list), 500):
            chunk = key_list[start:start + 500]
            placeholders = ",".join("?" for _ in chunk)
            for key, passed in connection.execute(
                f"SELECT cache_key, passed FROM results WHERE cache_key IN ({placeholders})",
                chunk,
            ):
                cached[key] = bool(passed)
        missing_keys = [key for key in key_list if key not in cached]
        missing_items = [unique[key] for key in missing_keys]
        if missing_items:
            if workers > 1:
                with ProcessPoolExecutor(max_workers=workers) as executor:
                    values = list(executor.map(_worker_check, missing_items, chunksize=16))
            else:
                evaluator = load_evaluator()
                values = [official_check(row, text, evaluator) for row, text in missing_items]
            connection.executemany(
                "INSERT OR REPLACE INTO results(cache_key, passed) VALUES (?, ?)",
                [(key, int(value)) for key, value in zip(missing_keys, values, strict=True)],
            )
            connection.commit()
            cached.update(zip(missing_keys, values, strict=True))
        return [cached[key] for key in keys]
    finally:
        connection.close()
