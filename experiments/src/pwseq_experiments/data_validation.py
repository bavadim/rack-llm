from __future__ import annotations

import json
from collections import Counter, defaultdict
from typing import Any

from .builders import MIXED_FAMILIES, SOFT_FAMILIES, build, build_mixed
from .common import DATA, file_hash, read_jsonl
from .hard_validation import hard_accepts_many

CLEAN_SPLITS = ("calibration", "dev", "test", "test_official")
FIXED_COUNTS = {
    "calibration": 360,
    "dev": 120,
    "hard_sanity": 60,
    "test_official": 67,
    "mixed": 720,
}


def _expected_counts(manifest: dict[str, Any]) -> dict[str, int]:
    counts = manifest.get("counts")
    expected_keys = {*FIXED_COUNTS, "test"}
    if not isinstance(counts, dict) or set(counts) != expected_keys:
        raise RuntimeError("manifest split-count inventory mismatch")
    if any(counts.get(split) != count for split, count in FIXED_COUNTS.items()):
        raise RuntimeError("fixed dataset cardinality changed")
    test_count = counts.get("test")
    family_count = len(SOFT_FAMILIES)
    if (
        not isinstance(test_count, int) or isinstance(test_count, bool)
        or test_count <= 0 or test_count % family_count
    ):
        raise RuntimeError(
            f"test count must be positive and divisible by {family_count}"
        )
    return {**FIXED_COUNTS, "test": test_count}


def _validate_rules(rows: list[dict[str, Any]]) -> None:
    checks: list[tuple[dict[str, Any], str, None]] = []
    identities: list[str] = []
    for row in rows:
        built = build(row["family"], row["kwargs"][0], row["max_tokens"])
        if built.hard_spec != row["hard_spec"] or built.weak_rules != row["weak_rules"]:
            raise RuntimeError(f"frozen builder mismatch: {row['id']}")
        rules = row["weak_rules"]
        polarities = [rule["polarity"] for rule in rules]
        if len(rules) != 10 or polarities.count("positive") != 6 or polarities.count("negative") != 4:
            raise RuntimeError(f"invalid two-author rule inventory: {row['id']}")
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


def _validate_noise(
    instances: dict[str, dict[str, Any]], manifest: dict[str, Any],
) -> None:
    levels = {
        level: {row["instance_id"]: row for row in read_jsonl(DATA / f"noise_{level}.jsonl")}
        for level in (20, 40)
    }
    plans = manifest.get("noise_family_plans", {})
    if set(plans) != set(SOFT_FAMILIES):
        raise RuntimeError("noise family-plan inventory mismatch")
    observed_types: set[str] = set()
    signatures: dict[tuple[int, str], set[tuple[tuple[str, str], ...]]] = defaultdict(set)
    compile_checks: list[tuple[dict[str, Any], str, None]] = []
    for level, overlays in levels.items():
        if set(overlays) != set(instances):
            raise RuntimeError(f"noise {level} instance set mismatch")
        for instance_id, overlay in overlays.items():
            instance = instances[instance_id]
            clean = instance["weak_rules"]
            changes = overlay["changes"]
            expected = plans[instance["family"]][:(2 if level == 20 else 4)]
            descriptors = [
                {key: change[key] for key in ("slot", "noise_type", "source_slot")
                 if key in change}
                for change in changes
            ]
            if descriptors != expected or len({change["slot"] for change in changes}) != len(changes):
                raise RuntimeError(f"noise family plan mismatch: {level}/{instance_id}")
            corrupted = [dict(rule) for rule in clean]
            for change in overlay["changes"]:
                source = clean[change["slot"]]
                if (source["polarity"], source["pattern"]) == (change["polarity"], change["pattern"]):
                    raise RuntimeError(f"no-op noise change: {level}/{instance_id}/{change['slot']}")
                corrupted[change["slot"]].update(
                    polarity=change["polarity"], pattern=change["pattern"],
                )
                observed_types.add(change["noise_type"])
                compile_checks.append((
                    {"kind": "ere", "pattern": change["pattern"]}, "", None,
                ))
            signatures[(level, instance["family"])].add(tuple(
                (rule["rule_id"], rule["polarity"]) for rule in corrupted
            ))
    for instance_id in instances:
        low = levels[20][instance_id]["changes"]
        high = levels[40][instance_id]["changes"]
        if low != high[:2]:
            raise RuntimeError(f"noise levels are not nested: {instance_id}")
    if any(len(values) != 1 for values in signatures.values()):
        raise RuntimeError("noise changes do not preserve one rule schema per family")
    expected_types = {
        "polarity_flip", "narrow_literal", "over_broad_pattern",
        "word_boundary_removal", "case_sensitivity_error",
        "duplicate_conflicting_rule",
    }
    if observed_types != expected_types:
        raise RuntimeError(f"noise corruption-type mismatch: {sorted(observed_types)}")
    # Compilation is the assertion; accepting the empty string is allowed for
    # deliberately over-broad corrupted rules.
    hard_accepts_many(compile_checks)


def validate_dataset() -> dict[str, Any]:
    """Validate the committed snapshot without creating or modifying any data."""
    manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("experiment_revision") != "5.0.0":
        raise RuntimeError("unexpected dataset revision")
    expected_counts = _expected_counts(manifest)
    rows_by_split = {
        name: read_jsonl(DATA / f"{name}.jsonl") for name in expected_counts
    }
    actual = {name: len(rows) for name, rows in rows_by_split.items()}
    if actual != expected_counts:
        raise RuntimeError(f"dataset cardinality mismatch: {actual}")
    expected_files = {
        f"{name}.jsonl" for name in expected_counts
    } | {"noise_20.jsonl", "noise_40.jsonl"}
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
    prompts_per_family = expected_counts["test"] // len(SOFT_FAMILIES)
    for split, per_family in (
        ("calibration", 30), ("dev", 10), ("test", prompts_per_family),
    ):
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
    for family in ("format:parentheses", "sentence:keyword"):
        family_rows = {
            split: [row for row in rows_by_split[split] if row["family"] == family]
            for split in ("calibration", "dev", "test")
        }
        bases = {
            split: {row.get("base_prompt") for row in rows}
            for split, rows in family_rows.items()
        }
        if any(None in values for values in bases.values()):
            raise RuntimeError(f"new-family base prompt is missing: {family}")
        for left, right in (("calibration", "dev"), ("calibration", "test"), ("dev", "test")):
            if bases[left] & bases[right]:
                raise RuntimeError(f"new-family base prompt overlap: {family}/{left}/{right}")
        parameter_values: dict[tuple[str, str], set[str]] = defaultdict(set)
        for split, rows in family_rows.items():
            for row in rows:
                for key, value in row["kwargs"][0].items():
                    if value is not None:
                        parameter_values[(split, key)].add(json.dumps(value, sort_keys=True))
        parameter_keys = {key for _split, key in parameter_values}
        for key in parameter_keys:
            for left, right in (("calibration", "dev"), ("calibration", "test"), ("dev", "test")):
                if parameter_values[(left, key)] & parameter_values[(right, key)]:
                    raise RuntimeError(f"new-family parameter overlap: {family}/{key}/{left}/{right}")

    _validate_rules(clean)
    _validate_mixed(rows_by_split["mixed"])
    _validate_noise({row["id"]: row for row in clean}, manifest)
    provenance_path = DATA / "authoring_provenance.json"
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if file_hash(provenance_path) != manifest.get("authoring_provenance_sha256"):
        raise RuntimeError("authoring provenance drift")
    if (
        not provenance.get("one_time_generation")
        or provenance.get("frozen_test_prompts") != expected_counts["test"]
    ):
        raise RuntimeError("one-time dataset provenance is missing")
    if provenance.get("experimental_models_used_for_authoring") is not False:
        raise RuntimeError("experimental model authoring separation is missing")
    if not provenance.get("authors_isolated_from_coordinator_context"):
        raise RuntimeError("independent author isolation is missing")
    if provenance.get("gold_labels_used_for_authoring") is not False:
        raise RuntimeError("gold-label authoring separation is missing")
    if provenance.get("coordinator_had_prior_failed_pilot_access") is not True:
        raise RuntimeError("coordinator pilot access is not disclosed")
    packet_hashes = provenance.get("authoring_packets_sha256", {})
    if set(packet_hashes) != {"author_a.json", "author_b.json", "reviewer.json"}:
        raise RuntimeError("authoring packet inventory mismatch")
    if manifest.get("authoring_packets_sha256") != packet_hashes:
        raise RuntimeError("manifest/provenance authoring packet hashes disagree")
    for name, expected in packet_hashes.items():
        if file_hash(DATA / name) != expected:
            raise RuntimeError(f"authoring packet drift: {name}")
    reviewer = json.loads((DATA / "reviewer.json").read_text(encoding="utf-8"))
    if reviewer.get("verdict") != "APPROVED":
        raise RuntimeError("blind reviewer did not approve the final rule packets")
    approved_hashes = reviewer.get("approved_packet_sha256")
    expected_approved_hashes = {
        name: packet_hashes[name] for name in ("author_a.json", "author_b.json")
    }
    if approved_hashes != expected_approved_hashes:
        raise RuntimeError("blind reviewer approval is not bound to the final author packets")
    return {"revision": manifest["experiment_revision"], "counts": actual, "valid": True}
