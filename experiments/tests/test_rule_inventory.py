from __future__ import annotations

import unittest

from pwseq_experiments.builders import SOFT_FAMILIES, build, empty_kwargs
from pwseq_experiments.hard_validation import ere_compiles_many, hard_accepts_many


def sample_kwargs(family: str):
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


class RuleInventoryRegressionTests(unittest.TestCase):
    def test_v4_family_replacements_are_frozen(self):
        self.assertNotIn("count:keywords_multiple", SOFT_FAMILIES)
        self.assertNotIn("format:line_indent", SOFT_FAMILIES)
        self.assertIn("format:parentheses", SOFT_FAMILIES)
        self.assertIn("sentence:keyword", SOFT_FAMILIES)
        self.assertEqual(len(SOFT_FAMILIES), 12)

    def test_two_blind_authors_supply_ten_native_eres_per_family(self):
        patterns = []
        rules_by_family = {}
        for family in SOFT_FAMILIES:
            rules = build(family, sample_kwargs(family), 384).weak_rules
            rules_by_family[family] = rules
            self.assertEqual([rule["slot"] for rule in rules], list(range(10)))
            self.assertEqual(sum(rule["polarity"] == "positive" for rule in rules), 6)
            self.assertEqual(sum(rule["polarity"] == "negative" for rule in rules), 4)
            identities = {(rule["polarity"], rule["pattern"]) for rule in rules}
            self.assertEqual(len(identities), 10, family)
            patterns.extend(rule["pattern"] for rule in rules)
        self.assertTrue(all(ere_compiles_many(patterns)))
        accepts_empty = hard_accepts_many([
            ({"kind": "ere", "pattern": rule["pattern"]}, "", None)
            for rules in rules_by_family.values() for rule in rules
        ])
        self.assertFalse(any(accepts_empty))

    def test_parameter_templates_are_fully_and_safely_rendered(self):
        cases = {
            "count:conjunctions": sample_kwargs("count:conjunctions"),
            "count:numbers": sample_kwargs("count:numbers"),
            "count:word_count_range": sample_kwargs("count:word_count_range"),
            "format:list": sample_kwargs("format:list"),
            "sentence:keyword": sample_kwargs("sentence:keyword"),
        }
        for family, kwargs in cases.items():
            for rule in build(family, kwargs, 384).weak_rules:
                self.assertNotRegex(rule["pattern"], r"\{[A-Za-z_][A-Za-z0-9_]*\}")

    def test_literal_and_quantifier_placeholders_are_unambiguous(self):
        sentence = build(
            "sentence:keyword", empty_kwargs(N=3, word="saffron"), 384
        ).weak_rules
        self.assertIn(")3[.)]", sentence[6]["pattern"])
        self.assertNotIn("){3}[.)]", sentence[6]["pattern"])
        numbers = build("count:numbers", empty_kwargs(N=7), 384).weak_rules
        self.assertIn("{7}", numbers[0]["pattern"])
        conjunctions = build(
            "count:conjunctions", empty_kwargs(small_n=6), 384
        ).weak_rules
        self.assertIn("{6}", conjunctions[0]["pattern"])


if __name__ == "__main__":
    unittest.main()
