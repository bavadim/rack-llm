#!/usr/bin/env python3

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import (
    check_answer,
    llama_completion_prompt,
    load_cases,
    parse_answer,
    select_cases,
    summary_rows,
    user_prompt,
)
from generate_dataset import solution_count


class EasySudokuTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = load_cases()

    def test_dataset_has_ten_cases_per_level(self):
        self.assertEqual(len(self.cases), 30)
        for missing_count in (3, 4, 5):
            self.assertEqual(
                len(select_cases(self.cases, missing=missing_count)),
                10,
            )

    def test_cases_are_valid_and_uniquely_solvable(self):
        for case in self.cases:
            self.assertEqual(case["missing_count"], len(case["cells"]))
            self.assertEqual(case["missing_count"], len(case["answer"]))
            self.assertEqual(solution_count(case["puzzle"]), 1)

            completed = [list(row) for row in case["puzzle"]]
            for cell, answer in zip(case["cells"], case["answer"]):
                row = int(cell[1]) - 1
                column = int(cell[3]) - 1
                self.assertEqual(case["puzzle"][row][column], ".")
                completed[row][column] = str(answer)

            expected = set("1234")
            for row in completed:
                self.assertEqual(set(row), expected)
            for column in range(4):
                self.assertEqual(
                    {completed[row][column] for row in range(4)},
                    expected,
                )
            for box_row in range(0, 4, 2):
                for box_column in range(0, 4, 2):
                    self.assertEqual(
                        {
                            completed[row][column]
                            for row in range(box_row, box_row + 2)
                            for column in range(box_column, box_column + 2)
                        },
                        expected,
                    )

    def test_answer_parser_is_strict(self):
        self.assertEqual(parse_answer("[4,3,2]", 3), (True, [4, 3, 2]))
        self.assertEqual(parse_answer("answer: [4,3,2]", 3), (False, []))
        self.assertEqual(parse_answer("[4,3]", 3), (False, []))
        self.assertEqual(parse_answer("[4,\"3\",2]", 3), (False, []))
        self.assertEqual(parse_answer("[4,7,2]", 3), (False, []))

    def test_gold_answers_pass(self):
        for case in self.cases:
            self.assertTrue(check_answer(case, case["answer"]))
            self.assertIn("Cells:", user_prompt(case))

    def test_native_completion_prompt_matches_llama_backend(self):
        self.assertEqual(
            llama_completion_prompt("system text", "user text"),
            "system: system text\nuser: user text",
        )

    def test_summary_reports_pass_at_one_and_pass_at_k(self):
        records = [
            {
                "case_id": "a",
                "missing_count": 2,
                "attempt": 1,
                "valid": True,
                "passed": False,
            },
            {
                "case_id": "a",
                "missing_count": 2,
                "attempt": 2,
                "valid": True,
                "passed": True,
            },
            {
                "case_id": "b",
                "missing_count": 2,
                "attempt": 1,
                "valid": True,
                "passed": True,
            },
        ]
        overall = summary_rows(records, 2)[0]
        self.assertEqual(overall["pass_at_1"], 1)
        self.assertEqual(overall["pass_at_k"], 2)
        self.assertEqual(overall["requested"], 4)


if __name__ == "__main__":
    unittest.main()
