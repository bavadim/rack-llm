from __future__ import annotations

import inspect
import json
import unittest
from collections import Counter, defaultdict

from pwseq_experiments.builders import (
    MIXED_FAMILIES,
    SOFT_FAMILIES,
    build,
    build_mixed,
    empty_kwargs,
)
from pwseq_experiments.common import DATA, file_hash, read_jsonl
from pwseq_experiments.data_validation import validate_dataset
from pwseq_experiments.hard_validation import ere_compiles_many, hard_accepts_many


def _sample_kwargs(family: str) -> dict:
    kwargs = empty_kwargs()
    if family == "count:conjunctions":
        kwargs["small_n"] = 6
    elif family == "count:numbers":
        kwargs["N"] = 10
    elif family == "count:word_count_range":
        kwargs.update(min_words=80, max_words=100)
    elif family == "format:list":
        kwargs["sep"] = "TEST+MARK[1]>"
    elif family == "sentence:keyword":
        kwargs.update(N=3, word="saffron")
    return kwargs


class DatasetTests(unittest.TestCase):
    def test_frozen_builders_reproduce_all_splits_through_blind_interfaces(self):
        self.assertEqual(
            list(inspect.signature(build).parameters),
            ["family", "kwargs", "max_tokens"],
        )
        self.assertEqual(
            list(inspect.signature(build_mixed).parameters),
            ["family", "kwargs", "max_tokens"],
        )
        for split in ("calibration", "dev", "test", "test_official"):
            for row in read_jsonl(DATA / f"{split}.jsonl"):
                built = build(row["family"], row["kwargs"][0], row["max_tokens"])
                self.assertEqual(built.hard_spec, row["hard_spec"], row["id"])
                expected = [
                    {
                        **rule,
                        "source_slot": rule["slot"],
                        "rule_id": built.weak_rules[index]["rule_id"],
                    }
                    for index, rule in enumerate(row["weak_rules"])
                ]
                self.assertEqual(built.weak_rules, expected, row["id"])

    def test_rule_inventory_is_distinct_compilable_and_parameterized(self):
        self.assertEqual(len(SOFT_FAMILIES), 12)
        patterns: list[str] = []
        rules_by_family = {}
        for family in SOFT_FAMILIES:
            rules = build(family, _sample_kwargs(family), 384).weak_rules
            rules_by_family[family] = rules
            self.assertEqual([rule["slot"] for rule in rules], list(range(10)))
            self.assertEqual(Counter(rule["polarity"] for rule in rules), {
                "positive": 6, "negative": 4,
            })
            self.assertEqual(
                len({(rule["polarity"], rule["pattern"]) for rule in rules}),
                len(rules),
                family,
            )
            for rule in rules:
                self.assertNotRegex(rule["pattern"], r"\{[A-Za-z_][A-Za-z0-9_]*\}")
                patterns.append(rule["pattern"])
        self.assertTrue(all(ere_compiles_many(patterns)))
        self.assertFalse(any(hard_accepts_many([
            ({"kind": "ere", "pattern": rule["pattern"]}, "", None)
            for rules in rules_by_family.values() for rule in rules
        ])))

    def test_splits_are_valid_balanced_and_disjoint(self):
        report = validate_dataset()
        self.assertTrue(report)
        manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
        for split, count in manifest["counts"].items():
            rows = read_jsonl(DATA / f"{split}.jsonl")
            self.assertEqual(len(rows), count, split)
            if split in {"calibration", "dev", "test"}:
                balance = Counter(row["family"] for row in rows)
                self.assertEqual(set(balance), set(SOFT_FAMILIES))
                self.assertEqual(len(set(balance.values())), 1)
        train = read_jsonl(DATA / "calibration.jsonl") + read_jsonl(DATA / "dev.jsonl")
        test = read_jsonl(DATA / "test.jsonl")
        self.assertFalse({row["prompt"] for row in train} & {row["prompt"] for row in test})
        parameter_values: dict[str, dict[tuple[str, str], set[str]]] = {}
        for name, rows in (("train", train), ("test", test)):
            values: dict[tuple[str, str], set[str]] = defaultdict(set)
            for row in rows:
                for key, value in row["kwargs"][0].items():
                    if value is not None:
                        values[(row["family"], key)].add(json.dumps(value, sort_keys=True))
            parameter_values[name] = values
        for key in parameter_values["train"].keys() & parameter_values["test"].keys():
            self.assertFalse(
                parameter_values["train"][key] & parameter_values["test"][key], key,
            )

    def test_authorship_provenance_binds_blind_packets_and_test_snapshot(self):
        provenance = json.loads(
            (DATA / "authoring_provenance.json").read_text(encoding="utf-8")
        )
        manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
        reviewer = json.loads((DATA / "reviewer.json").read_text(encoding="utf-8"))
        self.assertEqual(provenance["authoring_protocol"], "verifier-blind-v1")
        self.assertTrue(provenance["authors_isolated_from_coordinator_context"])
        self.assertFalse(provenance["gold_labels_used_for_authoring"])
        self.assertFalse(provenance["experimental_models_used_for_authoring"])
        self.assertEqual(provenance["frozen_test_prompts"], manifest["counts"]["test"])
        hashes = {
            name: file_hash(DATA / name)
            for name in ("author_a.json", "author_b.json", "reviewer.json")
        }
        self.assertEqual(provenance["authoring_packets_sha256"], hashes)
        self.assertEqual(manifest["authoring_packets_sha256"], hashes)
        self.assertEqual(
            reviewer["approved_packet_sha256"],
            {name: hashes[name] for name in ("author_a.json", "author_b.json")},
        )

    def test_mixed_rows_are_paired_and_only_change_the_hard_envelope(self):
        pairs: dict[str, list[dict]] = defaultdict(list)
        for row in read_jsonl(DATA / "mixed.jsonl"):
            pairs[row["pair_id"]].append(row)
        self.assertTrue(pairs)
        self.assertEqual(
            {row["family"].split("@", 1)[0] for rows in pairs.values() for row in rows},
            set(MIXED_FAMILIES),
        )
        for pair_id, arms in pairs.items():
            self.assertEqual(len(arms), 2, pair_id)
            by_arm = {row["mixed_arm"]: row for row in arms}
            self.assertEqual(set(by_arm), {"text_weak", "coarse_hard_weak"})
            weak, hard = by_arm["text_weak"], by_arm["coarse_hard_weak"]
            self.assertEqual(weak["weak_rules"], hard["weak_rules"])
            self.assertNotEqual(weak["hard_spec"], hard["hard_spec"])

    def test_noise_overlays_are_complete_effective_and_nested(self):
        base = {}
        for split in ("calibration", "dev", "test", "test_official"):
            base.update({row["id"]: row for row in read_jsonl(DATA / f"{split}.jsonl")})
        expected_types = {
            "polarity_flip", "narrow_literal", "over_broad_pattern",
            "word_boundary_removal", "case_sensitivity_error",
            "duplicate_conflicting_rule",
        }
        changed: dict[int, dict[str, set[tuple[int, str]]]] = {}
        for level in (20, 40):
            overlays = read_jsonl(DATA / f"noise_{level}.jsonl")
            self.assertEqual(len(overlays), len(base))
            seen = set()
            changed[level] = {}
            for overlay in overlays:
                source = base[overlay["instance_id"]]
                entries = set()
                for change in overlay["changes"]:
                    clean = source["weak_rules"][change["slot"]]
                    self.assertNotEqual(
                        (clean["polarity"], clean["pattern"]),
                        (change["polarity"], change["pattern"]),
                    )
                    seen.add(change["noise_type"])
                    entries.add((change["slot"], change["noise_type"]))
                changed[level][overlay["instance_id"]] = entries
            self.assertEqual(seen, expected_types)
        for instance_id in base:
            self.assertLessEqual(changed[20][instance_id], changed[40][instance_id])


if __name__ == "__main__":
    unittest.main()
