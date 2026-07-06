#!/usr/bin/env python3
"""Unit tests for Experiment 007 soft rule construction."""

from __future__ import annotations

import ast
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_soft_rules import ROOT_DATA_DIR, build_dataset, read_jsonl, soft_supported_ids
from soft_rules import RuleSpec, build_soft_rules


REPO_ROOT = Path(__file__).resolve().parents[3]
SOFT_RULES_PATH = Path(__file__).resolve().parent / "soft_rules.py"
REQUIRED_FIELDS = {
    "rule_id",
    "source_instruction_id",
    "kind",
    "weight",
    "pattern_type",
    "pattern",
    "polarity",
    "noise",
    "noise_type",
    "description",
}


def load_snapshot() -> list[dict]:
    return read_jsonl(ROOT_DATA_DIR / "ifbench_snapshot.jsonl")


def soft_rows() -> list[dict]:
    supported = soft_supported_ids()
    return [
        row
        for row in load_snapshot()
        if all(instruction_id in supported for instruction_id in row["instruction_id_list"])
    ]


def assert_rule_schema(rule: RuleSpec) -> None:
    payload = rule.to_json()
    assert set(payload) == REQUIRED_FIELDS, payload
    assert isinstance(payload["rule_id"], str) and payload["rule_id"]
    assert isinstance(payload["source_instruction_id"], str) and payload["source_instruction_id"]
    assert payload["kind"] in {"rank", "ban"}
    assert isinstance(payload["weight"], float)
    assert payload["pattern_type"] in {"regex", "literal", "structure"}
    assert isinstance(payload["pattern"], str) and payload["pattern"]
    assert payload["polarity"] in {"positive", "negative"}
    assert isinstance(payload["noise"], bool)
    if payload["noise"]:
        assert isinstance(payload["noise_type"], str) and payload["noise_type"]
    else:
        assert payload["noise_type"] is None
    assert isinstance(payload["description"], str) and payload["description"]


def test_rule_schema_valid() -> None:
    rows = soft_rows()
    assert rows, "expected at least one soft-supported row"
    for row in rows:
        for noise_level in (0.0, 0.2, 0.4):
            rules = build_soft_rules(row, noise_level)
            assert len(rules) >= 3
            for rule in rules:
                assert_rule_schema(rule)


def test_noise_ratio() -> None:
    for row in soft_rows():
        clean = build_soft_rules(row, 0.0)
        clean_local_count = sum(1 for rule in clean if rule.source_instruction_id != "universal")
        for noise_level in (0.2, 0.4):
            noisy = build_soft_rules(row, noise_level)
            added_noise_count = sum(1 for rule in noisy if rule.noise)
            expected = max(1, math.ceil(clean_local_count * noise_level))
            assert abs(added_noise_count - expected) <= 1, (row["key"], noise_level, added_noise_count, expected)


def test_no_verifier_import() -> None:
    tree = ast.parse(SOFT_RULES_PATH.read_text(encoding="utf-8"))
    forbidden_modules = {"evaluation_lib", "instructions_registry"}
    forbidden_names = {
        "ContentChecker",
        "FormatChecker",
        "KeywordChecker",
        "NumberChecker",
        "PunctuationChecker",
        "ResponseChecker",
    }
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name.split(".")[0] not in forbidden_modules
        elif isinstance(node, ast.ImportFrom):
            assert (node.module or "").split(".")[0] not in forbidden_modules
            for alias in node.names:
                assert alias.name not in forbidden_names


def test_keywords_rules() -> None:
    row = next(row for row in load_snapshot() if row["instruction_id_list"] == ["count:keywords_multiple"])
    kwargs = row["kwargs"][0]
    rules = build_soft_rules(row, 0.0)
    patterns = "\n".join(rule.pattern for rule in rules)
    for index in range(1, 6):
        keyword = kwargs[f"keyword{index}"]
        assert keyword
        assert keyword in patterns


def test_position_rules() -> None:
    row = next(row for row in load_snapshot() if row["instruction_id_list"] == ["words:keywords_specific_position"])
    kwargs = row["kwargs"][0]
    rules = build_soft_rules(row, 0.0)
    patterns = "\n".join(rule.pattern for rule in rules)
    descriptions = "\n".join(rule.description for rule in rules)
    assert kwargs["keyword"] in patterns
    assert f"{{{max(1, int(kwargs['n']) - 3)}," in patterns
    assert f"{{{max(1, int(kwargs['m']) - 5)}," in patterns
    assert "sentence-position" in descriptions
    assert "word-position" in descriptions


def test_dataset_shape_and_coverage_file() -> None:
    dataset, failures = build_dataset(load_snapshot(), soft_supported_ids())
    assert len(dataset) == len(soft_rows())
    assert failures
    assert any(failure["key"] == "__coverage__" for failure in failures)
    for row in dataset:
        assert set(row["rule_sets"]) == {"clean", "noisy_20", "noisy_40"}
        assert not any(rule["noise"] for rule in row["rule_sets"]["clean"])
        assert any(rule["noise"] for rule in row["rule_sets"]["noisy_20"])
        assert any(rule["noise"] for rule in row["rule_sets"]["noisy_40"])


def main() -> int:
    tests = [
        test_rule_schema_valid,
        test_noise_ratio,
        test_no_verifier_import,
        test_keywords_rules,
        test_position_rules,
        test_dataset_shape_and_coverage_file,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
