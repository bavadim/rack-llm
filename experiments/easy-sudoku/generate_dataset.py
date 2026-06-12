#!/usr/bin/env python3

import argparse
import json
import random
from pathlib import Path

from common import DEFAULT_DATASET


BASE = (
    "1234",
    "3412",
    "2143",
    "4321",
)


def shuffled_solution(rng):
    digits = list("1234")
    rng.shuffle(digits)
    translation = dict(zip("1234", digits))

    bands = [0, 1]
    stacks = [0, 1]
    rng.shuffle(bands)
    rng.shuffle(stacks)

    columns = []
    for stack in stacks:
        columns_in_stack = [0, 1]
        rng.shuffle(columns_in_stack)
        columns.extend(2 * stack + column for column in columns_in_stack)

    rows = []
    for band in bands:
        rows_in_band = [0, 1]
        rng.shuffle(rows_in_band)
        for row_in_band in rows_in_band:
            source_row = BASE[2 * band + row_in_band]
            rows.append("".join(translation[source_row[column]] for column in columns))
    return rows


def make_case(rng, missing_count, case_number):
    for _ in range(10_000):
        solution = shuffled_solution(rng)
        positions = sorted(rng.sample(range(16), missing_count))
        puzzle = [list(row) for row in solution]
        cells = []
        answer = []
        for position in positions:
            row, column = divmod(position, 4)
            cells.append(f"r{row + 1}c{column + 1}")
            answer.append(int(solution[row][column]))
            puzzle[row][column] = "."

        rendered = ["".join(row) for row in puzzle]
        if solution_count(rendered, limit=2) == 1:
            return {
                "id": f"easy-{missing_count}-{case_number:02d}",
                "missing_count": missing_count,
                "puzzle": rendered,
                "cells": cells,
                "answer": answer,
            }
    raise RuntimeError(f"could not generate a unique case with {missing_count} blanks")


def solution_count(puzzle, limit=2):
    board = [list(row) for row in puzzle]

    def candidates(row, column):
        used = set(board[row])
        used.update(board[index][column] for index in range(4))
        box_row = 2 * (row // 2)
        box_column = 2 * (column // 2)
        used.update(
            board[r][c]
            for r in range(box_row, box_row + 2)
            for c in range(box_column, box_column + 2)
        )
        return [digit for digit in "1234" if digit not in used]

    def search():
        best = None
        best_candidates = None
        for row in range(4):
            for column in range(4):
                if board[row][column] != ".":
                    continue
                options = candidates(row, column)
                if not options:
                    return 0
                if best_candidates is None or len(options) < len(best_candidates):
                    best = (row, column)
                    best_candidates = options
        if best is None:
            return 1

        row, column = best
        count = 0
        for digit in best_candidates:
            board[row][column] = digit
            count += search()
            board[row][column] = "."
            if count >= limit:
                return count
        return count

    return search()


def generate(seed=20260612, cases_per_level=10):
    rng = random.Random(seed)
    return [
        make_case(rng, missing_count, case_number)
        for missing_count in (2, 3, 4)
        for case_number in range(1, cases_per_level + 1)
    ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=20260612)
    parser.add_argument("--cases-per-level", type=int, default=10)
    parser.add_argument("--output", type=Path, default=DEFAULT_DATASET)
    args = parser.parse_args()

    cases = generate(args.seed, args.cases_per_level)
    with args.output.open("w", encoding="utf-8") as destination:
        for case in cases:
            destination.write(json.dumps(case, ensure_ascii=True) + "\n")
    print(f"Wrote {len(cases)} cases to {args.output}")


if __name__ == "__main__":
    main()
