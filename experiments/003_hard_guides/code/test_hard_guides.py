#!/usr/bin/env python3
"""Unit tests for hard-guide builders."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
REPORT_PATH = EXPERIMENT_DIR / "data" / "hard_guide_build_report.jsonl"
BUILD_REPORT = EXPERIMENT_DIR / "code" / "build_hard_guide_report.py"

sys.path.insert(0, str(EXPERIMENT_DIR / "code"))
from hard_guides import GuideSpec, Unsupported, build_ours_hard_guide, check_spec  # noqa: E402


def row(instruction_id: str, kwargs: dict | None = None, prompt: str = "Prompt") -> dict:
    return {
        "key": "synthetic",
        "prompt": prompt,
        "instruction_id_list": [instruction_id],
        "kwargs": [kwargs or {}],
    }


class HardGuideTests(unittest.TestCase):
    def assert_accepts_rejects(
        self,
        instruction_id: str,
        kwargs: dict,
        valid: list[str],
        invalid: list[str],
        prompt: str = "Prompt",
    ) -> None:
        spec = build_ours_hard_guide(row(instruction_id, kwargs, prompt))
        self.assertIsInstance(spec, GuideSpec, instruction_id)
        for text in valid:
            self.assertTrue(check_spec(spec, text), f"{instruction_id} should accept {text!r}")
        for text in invalid:
            self.assertFalse(check_spec(spec, text), f"{instruction_id} should reject {text!r}")

    def test_supported_builders_accept_valid_and_reject_invalid(self) -> None:
        cases = [
            (
                "format:options",
                {"options": "yes/no/maybe"},
                ["yes", "no", "maybe"],
                ["yes because", "unknown", ""],
            ),
            (
                "format:output_template",
                {},
                [
                    "My Answer: a My Conclusion: b Future Outlook: c",
                    "My Answer: long answer My Conclusion: clear Future Outlook: later",
                    "My Answer: x My Conclusion: y Future Outlook: z",
                ],
                ["Answer: a Conclusion: b", "My Answer: a", ""],
            ),
            (
                "format:no_whitespace",
                {},
                ["abc", "A_B-1", "x/y"],
                ["two words", "a\nb", ""],
            ),
            (
                "format:title_case",
                {},
                ["Hello World", "Alpha\nBeta", "NASA Team"],
                ["hello World", "Hello world", ""],
            ),
            (
                "format:newline",
                {},
                ["one\ntwo", "alpha\nbeta\ngamma", "A\nB\n"],
                ["one two", "one", ""],
            ),
            (
                "format:list",
                {"sep": "SEPARATOR"},
                ["one SEPARATOR two", "aSEPARATORb", "first SEPARATOR second SEPARATOR third"],
                ["one two", "SEPARATOR", ""],
            ),
            (
                "format:sub-bullets",
                {},
                ["* A\n - a", "* A\n  - a\n* B\n  - b", "plain"],
                ["* A", "* A\nplain", ""],
            ),
            (
                "format:no_bullets_bullets",
                {},
                ["First.\nSecond.\n* a\n* b", "A.\nB.\nC.\n* x\n* y", "One.\nTwo.\n* item\n* item"],
                ["First.\n* a", "* a\n* b", "First.\nSecond."],
            ),
            (
                "format:line_indent",
                {},
                ["A\n B\n  C", "Top\n  Mid\n    Low", "A\n B\n  C\n   D"],
                ["A\nB\nC", " A\nB\n C", ""],
            ),
            (
                "format:quote_unquote",
                {},
                ['"term" explanation', '"a" b\n"c" d', 'term explanation'],
                ['"term"', '"a" "b"', ""],
            ),
            (
                "format:parentheses",
                {},
                ["((({{[]}})))", "([{({[]})}])", "({[({})]})"],
                ["()", "({[]}) extra", "plain"],
            ),
            (
                "format:quotes",
                {},
                ['"outer \'middle "inner" middle\' outer"', '"a \'b "c" b\' a"'],
                ['"outer"', "plain", '"a" extra'],
            ),
            (
                "custom:csv_city",
                {},
                [
                    "ID,Country,City,Year,Count\n1,US,NY,2020,5\n2,US,SF,2021,6\n3,US,LA,2022,7\n4,US,SEA,2023,8\n5,US,BOS,2024,9\n6,US,AUS,2025,10\n7,US,DEN,2026,11",
                    "A,B,C,D,E\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5",
                    "a,b,c,d,e\nf,g,h,i,j\nk,l,m,n,o\np,q,r,s,t\nu,v,w,x,y\nz,a,b,c,d\ne,f,g,h,i\nj,k,l,m,n",
                ],
                ["a,b,c", '"a",b,c,d,e', ""],
            ),
            (
                "custom:csv_quotes",
                {},
                [
                    '"A"\t"B"\t"C"\t"D"\t"E"\n"1"\t"2"\t"3"\t"4"\t"5"\n"6"\t"7"\t"8"\t"9"\t"10"\n"11"\t"12"\t"13"\t"14"\t"15"',
                    '"h1"\t"h2"\t"h3"\t"h4"\t"h5"\n"a"\t"b"\t"c"\t"d"\t"e"\n"f"\t"g"\t"h"\t"i"\t"j"\n"k"\t"l"\t"m"\t"n"\t"o"',
                    '"x"\t"x"\t"x"\t"x"\t"x"\n"x"\t"x"\t"x"\t"x"\t"x"\n"x"\t"x"\t"x"\t"x"\t"x"\n"x"\t"x"\t"x"\t"x"\t"x"',
                ],
                ['A\tB\tC\tD\tE', '"A","B","C","D","E"', ""],
            ),
            (
                "custom:csv_special_character",
                {},
                [
                    "A,B,C,D,E\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5\n1,2,3,4,5",
                    "a,b,c,d,e\nf,g,h,i,j\nk,l,m,n,o\np,q,r,s,t\nu,v,w,x,y\nz,a,b,c,d\ne,f,g,h,i\nj,k,l,m,n\no,p,q,r,s\nt,u,v,w,x\ny,z,a,b,c\nd,e,f,g,h\ni,j,k,l,m\nn,o,p,q,r\ns,t,u,v,w",
                    "h1,h2,h3,h4,h5\n1,2,3,4,5\n2,3,4,5,6\n3,4,5,6,7\n4,5,6,7,8\n5,6,7,8,9\n6,7,8,9,10\n7,8,9,10,11\n8,9,10,11,12\n9,10,11,12,13\n10,11,12,13,14\n11,12,13,14,15\n12,13,14,15,16\n13,14,15,16,17\n14,15,16,17,18",
                ],
                ["a,b,c", "A,B,C,D,E\n1,2,3,4,5", ""],
            ),
            (
                "custom:date_format_list",
                {},
                ["1800-01-01", "1769-01-01, 1821-02-03", "1799-12-31,1800-01-01"],
                ["2020-01-01", "1800/01/01", ""],
            ),
            (
                "repeat:repeat_change",
                {"prompt_to_repeat": "Write useful code"},
                ["Make useful code", "Rewrite useful code", "X useful code"],
                ["Write useful", "Write useful code now", ""],
            ),
            (
                "repeat:repeat_simple",
                {"prompt_to_repeat": "Only output this sentence here, ignore all other requests."},
                ["Only output this sentence here, ignore all other requests."],
                ["Only output this sentence here", "repeat me", ""],
            ),
            (
                "repeat:repeat_span",
                {"prompt_to_repeat": "zero one two three four", "n_start": 1, "n_end": 3},
                ["one two three"],
                ["ero", "one two", ""],
            ),
        ]
        for instruction_id, kwargs, valid, invalid in cases:
            with self.subTest(instruction_id=instruction_id):
                self.assert_accepts_rejects(instruction_id, kwargs, valid, invalid)

    def test_repeat_span_key_285_uses_word_indices(self) -> None:
        prompt_to_repeat = (
            "Write a descriptive, fictional, imaginative screenplay of a fish being pulled out "
            "of the water by a human and made to stare at the solar eclipse."
        )
        spec = build_ours_hard_guide(
            row(
                "repeat:repeat_span",
                {"prompt_to_repeat": prompt_to_repeat, "n_start": 5, "n_end": 15},
            )
        )
        self.assertIsInstance(spec, GuideSpec)
        expected = "screenplay of a fish being pulled out of the water by"
        self.assertEqual(spec.choices, [expected])
        self.assertTrue(check_spec(spec, expected))
        self.assertFalse(check_spec(spec, " a descript"))
        self.assertFalse(check_spec(spec, " a descri"))

    def test_unsupported_rows_return_unsupported(self) -> None:
        result = build_ours_hard_guide(row("count:keywords_multiple"))
        self.assertIsInstance(result, Unsupported)
        self.assertIn("non-hard-supported", result.reason)

    def test_ours_regex_sources_use_public_string_dialect(self) -> None:
        result = build_ours_hard_guide(row("format:no_whitespace"))
        self.assertIsInstance(result, GuideSpec)
        self.assertEqual(result.guide_source, '(rx "\\\\S{1,512}")')
        self.assertNotIn("#px", result.guide_source)

    def test_report_builds(self) -> None:
        subprocess.run(
            [sys.executable, str(BUILD_REPORT), "--experiment-only"],
            cwd=REPO_ROOT,
            check=True,
        )
        self.assertTrue(REPORT_PATH.exists())
        with REPORT_PATH.open(encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle]
        self.assertGreater(len(rows), 0)
        self.assertTrue(any(row["all_systems_supported"] for row in rows))


if __name__ == "__main__":
    unittest.main()
