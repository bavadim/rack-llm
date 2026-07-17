from __future__ import annotations

import unittest

from pwseq_experiments.builders import EMOJI_ALT, EMOJIS, rules_emoji, rules_indent
from pwseq_experiments.hard_validation import hard_accepts, hard_accepts_many


class RuleInventoryRegressionTests(unittest.TestCase):
    def test_emoji_inventory_has_no_empty_regex_alternative(self):
        self.assertEqual(len(EMOJIS), 12)
        self.assertTrue(all(isinstance(value, str) and value for value in EMOJIS))
        self.assertEqual(len(EMOJIS), len(set(EMOJIS)))
        self.assertFalse(hard_accepts({"kind": "ere", "pattern": EMOJI_ALT}, ""))
        self.assertFalse(hard_accepts({"kind": "ere", "pattern": EMOJI_ALT}, "plain text"))
        for emoji in EMOJIS:
            self.assertTrue(
                hard_accepts({"kind": "ere", "pattern": EMOJI_ALT}, emoji),
                emoji,
            )
        patterns = [rule["pattern"] for rule in rules_emoji({})]
        self.assertTrue(all(patterns))
        self.assertEqual(len(patterns), len(set(patterns)))

    def test_indent_rules_have_distinct_native_fire_columns(self):
        rules = rules_indent({})
        self.assertEqual(len(rules), 6)
        identities = [(rule["polarity"], rule["pattern"]) for rule in rules]
        self.assertEqual(len(identities), len(set(identities)))

        probes = [
            "head\n one",
            "head\n  two",
            "head\n   three",
            "head\n  first\n  second",
            "head\n   parent\n  child",
            "head\n    four",
        ]
        checks = [
            (
                {
                    "kind": "ere",
                    # Weak ERE rules are substring observers.  The hard ERE
                    # validator is full-match, so add the same surrounding
                    # text language used by the observer implementation.
                    "pattern": f"(.|\\n)*({rule['pattern']})(.|\\n)*",
                },
                probe,
                None,
            )
            for probe in probes
            for rule in rules
        ]
        flat = hard_accepts_many(checks)
        matrix = [flat[index:index + len(rules)] for index in range(0, len(flat), len(rules))]
        columns = list(zip(*matrix, strict=True))
        self.assertEqual(len(columns), len(set(columns)))
        self.assertEqual(matrix[0], [True, False, False, False, False, False])
        self.assertEqual(matrix[1], [False, True, False, False, False, False])
        self.assertEqual(matrix[2], [False, False, True, False, False, False])
        self.assertEqual(matrix[3], [False, True, False, True, False, False])
        self.assertEqual(matrix[4], [False, True, True, False, True, False])
        self.assertEqual(matrix[5], [False, False, False, False, False, True])


if __name__ == "__main__":
    unittest.main()
