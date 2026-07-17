from __future__ import annotations

import json
from collections import Counter, defaultdict
from typing import Any

from .builders import MIXED_FAMILIES, SOFT_FAMILIES, build, build_mixed
from .common import DATA, file_hash, read_jsonl
from .hard_validation import hard_accepts_many

CLEAN_SPLITS = ("calibration", "dev", "test", "test_official")
EXPECTED_COUNTS = {
    "calibration": 360,
    "dev": 120,
    "hard_sanity": 60,
    "test": 600,
    "test_official": 67,
    "mixed": 720,
}


def _validate_rules(rows: list[dict[str, Any]]) -> None:
    checks: list[tuple[dict[str, Any], str, None]] = []
    identities: list[str] = []
    for row in rows:
        built = build(row["family"], row["kwargs"][0], row["max_tokens"])
        if built.hard_spec != row["hard_spec"] or built.weak_rules != row["weak_rules"]:
            raise RuntimeError(f"frozen builder mismatch: {row['id']}")
        rules = row["weak_rules"]
        if [rule["slot"] for rule in rules] != list(range(len(rules))):
            raise RuntimeError(f"non-contiguous rule slots: {row['id']}")
        keys = [(rule["polarity"], rule["pattern"]) for rule in rules]
        if len(keys) != len(set(keys)):
            raise RuntimeError(f"duplicate rules: {row['id']}")
        for rule in rules:
            if not rule["pattern"]:
                raise RuntimeError(f"empty rule: {row['id']}:{rule['slot']}")
            checks.append(({"kind": "ere", "pattern": rule["pattern"]}, "", None))
            identities.append(f"{row['id']}:{rule['slot']}")
    for identity, accepts_empty in zip(identities, hard_accepts_many(checks), strict=True):
        if accepts_empty:
            raise RuntimeError(f"rule accepts empty text: {identity}")


def _validate_mixed(rows: list[dict[str, Any]]) -> None:
    pairs: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        pairs[row["pair_id"]].append(row)
        family = row["constraint_family"]
        expected = (
            build_mixed(family, row["kwargs"][0], row["max_tokens"])
            if row["mixed_arm"] == "coarse_hard_weak"
            else build(family, row["kwargs"][0], row["max_tokens"])
        )
        if row["hard_spec"] != expected.hard_spec or row["weak_rules"] != expected.weak_rules:
            raise RuntimeError(f"mixed builder mismatch: {row['id']}")
    for pair_id, pair in pairs.items():
        if len(pair) != 2 or {row["mixed_arm"] for row in pair} != {"text_weak", "coarse_hard_weak"}:
            raise RuntimeError(f"invalid mixed pair: {pair_id}")


def _validate_noise(instances: dict[str, dict[str, Any]]) -> None:
    levels = {
        level: {row["instance_id"]: row for row in read_jsonl(DATA / f"noise_{level}.jsonl")}
        for level in (20, 40)
    }
    for level, overlays in levels.items():
        if set(overlays) != set(instances):
            raise RuntimeError(f"noise {level} instance set mismatch")
        for instance_id, overlay in overlays.items():
            clean = instances[instance_id]["weak_rules"]
            for change in overlay["changes"]:
                source = clean[change["slot"]]
                if (source["polarity"], source["pattern"]) == (change["polarity"], change["pattern"]):
                    raise RuntimeError(f"no-op noise change: {level}/{instance_id}/{change['slot']}")
    for instance_id in instances:
        low = {(x["slot"], x["noise_type"]) for x in levels[20][instance_id]["changes"]}
        high = {(x["slot"], x["noise_type"]) for x in levels[40][instance_id]["changes"]}
        if not low <= high:
            raise RuntimeError(f"noise levels are not nested: {instance_id}")


def validate_dataset() -> dict[str, Any]:
    """Validate the committed snapshot without creating or modifying any data."""
    manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("experiment_revision") != "3.1.0":
        raise RuntimeError("unexpected dataset revision")
    rows_by_split = {name: read_jsonl(DATA / f"{name}.jsonl") for name in EXPECTED_COUNTS}
    actual = {name: len(rows) for name, rows in rows_by_split.items()}
    if actual != EXPECTED_COUNTS or manifest.get("counts") != EXPECTED_COUNTS:
        raise RuntimeError(f"dataset cardinality mismatch: {actual}")
    expected_files = {f"{name}.jsonl" for name in EXPECTED_COUNTS} | {"noise_20.jsonl", "noise_40.jsonl"}
    if set(manifest.get("files", {})) != expected_files:
        raise RuntimeError("manifest JSONL file set mismatch")
    if {path.name for path in DATA.glob("*.jsonl")} != expected_files:
        raise RuntimeError("unexpected JSONL file in frozen dataset")
    for name, expected in manifest["files"].items():
        if file_hash(DATA / name) != expected:
            raise RuntimeError(f"frozen dataset drift: {name}")

    clean = [row for split in CLEAN_SPLITS for row in rows_by_split[split]]
    ids = [row["id"] for row in clean]
    if len(ids) != len(set(ids)):
        raise RuntimeError("duplicate clean instance id")
    for split in CLEAN_SPLITS:
        if any(row["split"] != split for row in rows_by_split[split]):
            raise RuntimeError(f"incorrect split field: {split}")
    for split, per_family in (("calibration", 30), ("dev", 10), ("test", 50)):
        counts = Counter(row["family"] for row in rows_by_split[split])
        if counts != Counter({family: per_family for family in SOFT_FAMILIES}):
            raise RuntimeError(f"family balance mismatch: {split}")
    test_prompts = [row["prompt"] for row in rows_by_split["test"]]
    base_prompts = [row.get("base_prompt") for row in rows_by_split["test"]]
    train_prompts = {row["prompt"] for split in ("calibration", "dev") for row in rows_by_split[split]}
    if (
        None in base_prompts
        or len(test_prompts) != len(set(test_prompts))
        or len(base_prompts) != len(set(base_prompts))
        or train_prompts & (set(test_prompts) | set(base_prompts))
    ):
        raise RuntimeError("test prompt uniqueness/disjointness failed")
    train_values: dict[tuple[str, str], set[str]] = defaultdict(set)
    test_values: dict[tuple[str, str], set[str]] = defaultdict(set)
    for target, source in (
        (train_values, [row for split in ("calibration", "dev") for row in rows_by_split[split]]),
        (test_values, rows_by_split["test"]),
    ):
        for row in source:
            for key, value in row["kwargs"][0].items():
                if value is not None:
                    target[(row["family"], key)].add(json.dumps(value, sort_keys=True))
    for key in train_values.keys() & test_values.keys():
        if train_values[key] & test_values[key]:
            raise RuntimeError(f"test parameter overlap: {key}")

    _validate_rules(clean)
    _validate_mixed(rows_by_split["mixed"])
    _validate_noise({row["id"]: row for row in clean})
    provenance_path = DATA / "authoring_provenance.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if file_hash(provenance_path) != manifest.get("authoring_provenance_sha256"):
        raise RuntimeError("authoring provenance drift")
    if not provenance.get("one_time_generation") or provenance.get("frozen_test_prompts") != 600:
        raise RuntimeError("one-time dataset provenance is missing")
    if provenance.get("experimental_models_used_for_authoring") is not False:
        raise RuntimeError("experimental model authoring separation is missing")
    return {"revision": manifest["experiment_revision"], "counts": actual, "valid": True}
