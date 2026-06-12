#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from ppbench import Puzzle
from ppbench.benchmarks.strategies.direct_ask import (
    example_of_inputs,
    get_example_move_context,
    get_rules_for_puzzle,
)

EXPERIMENT_DIR = Path(__file__).resolve().parent
DATASET_PATH = EXPERIMENT_DIR / "dataset.jsonl"
RACKET_PROGRAM = EXPERIMENT_DIR / "rack_llm_sample.rkt"


def load_records():
    with DATASET_PATH.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def prompts(puzzle):
    ticks = "```"
    system_prompt = (
        "Solve the puzzle!!\n\n"
        "Answer with a list of moves you would like to make that solve the "
        "puzzle as json in a markdown json code block\n\n"
        f"{ticks}json\n"
        '["mouse,left,1,1", "mouse,right,3,1", ... ]\n'
        f"{ticks}"
    )
    user_prompt = f"""
Puzzle Type: {puzzle.pid}
Puzzle Rules:
{ticks}
{get_rules_for_puzzle(puzzle)}
{ticks}

Here is an example of inputs / a solved puzzle (lots of context for you)
{ticks}
{example_of_inputs(puzzle)}
{ticks}
Here's some more:
{get_example_move_context(puzzle)}
Note specifically how the coordinate systems work (for the puzzle vs. the inputs).
For the puzzle you are working on, ensure you fully understand from the example of input above, that the move is exactly where you expect.
==== ==== ==== ==== ====
Here is the puzzle you are to solve:
{puzzle.get_string_repr()}

==== ==== ==== ==== ====
Please now solve it.
"""
    return system_prompt, user_prompt


def parse_moves(output):
    match = re.search(r"```(?:json)?\s*(\[.*?\])\s*```", output, re.DOTALL)
    raw_json = match.group(1) if match else output
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError:
        return False, []
    if isinstance(data, list) and all(isinstance(item, str) for item in data):
        return True, data
    return False, []


def check_moves(url, moves):
    puzzle = Puzzle.from_url(url)
    try:
        for move in moves:
            puzzle.send_move(move)
        return puzzle.is_complete()
    except Exception:
        return False


def select_records(puzzle_type, index):
    records = load_records()
    if puzzle_type:
        records = [record for record in records if record["pid"] == puzzle_type]
    if not records:
        raise SystemExit(f"No golden_30 puzzles with type {puzzle_type!r}")
    if index is not None and index >= len(records):
        raise SystemExit(
            f"Index {index} is out of range for {puzzle_type!r}; "
            f"available: 0..{len(records) - 1}"
        )
    return [records[index]] if index is not None else records


def run_puzzle(record, puzzle_number, puzzle_count, show_output, timeout):
    puzzle = Puzzle.from_url(record["puzzlink_url"])
    system_prompt, user_prompt = prompts(puzzle)
    request = {
        "system_prompt": system_prompt,
        "user_prompt": user_prompt,
    }

    print(
        f"\n[{puzzle_number}/{puzzle_count}] "
        f"{record['pid']} | {record['puzzlink_url']}"
    )
    started = time.monotonic()
    try:
        process = subprocess.run(
            ["racket", str(RACKET_PROGRAM)],
            input=json.dumps(request),
            stdout=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - started
        print(f"  TIMEOUT after {elapsed:.1f}s")
        return False, 0, 0, True
    elapsed = time.monotonic() - started
    if process.returncode != 0:
        print("  ERROR")
        return False, 0, 0, True

    try:
        outputs = json.loads(process.stdout)["outputs"]
    except (json.JSONDecodeError, KeyError, TypeError):
        print("  ERROR | invalid Racket output")
        print(process.stdout.rstrip())
        return False, 0, 0, True

    solved = False
    valid_count = 0
    for variant_number, output in enumerate(outputs, start=1):
        valid_json, moves = parse_moves(output)
        passed = valid_json and check_moves(record["puzzlink_url"], moves)
        valid_count += int(valid_json)
        solved = solved or passed
        print(
            f"  [{variant_number}/{len(outputs)}] "
            f"{'PASS' if passed else 'FAIL'} | "
            f"JSON: {'valid' if valid_json else 'invalid'} | "
            f"{len(moves)} moves"
        )
        if show_output:
            print(output)

    print(
        f"  pass@10: {int(solved)} | "
        f"valid JSON: {valid_count}/{len(outputs)} | "
        f"{elapsed:.1f}s"
    )
    return solved, valid_count, len(outputs), False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--puzzle-type")
    parser.add_argument("--index", type=int)
    parser.add_argument("--show-output", action="store_true")
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help="optional maximum seconds per puzzle",
    )
    args = parser.parse_args()

    if args.index is not None and args.index < 0:
        parser.error("--index must be non-negative")
    if args.timeout is not None and args.timeout <= 0:
        parser.error("--timeout must be positive")

    records = select_records(args.puzzle_type, args.index)
    puzzle_count = len(records)
    passed_puzzles = 0
    valid_variants = 0
    total_variants = 0
    errors = 0
    started = time.monotonic()

    print(f"Running rack-llm on {puzzle_count} puzzle(s), up to 10 variants each")
    for puzzle_number, record in enumerate(records, start=1):
        passed, valid, variants, failed = run_puzzle(
            record,
            puzzle_number,
            puzzle_count,
            args.show_output,
            args.timeout,
        )
        passed_puzzles += int(passed)
        valid_variants += valid
        total_variants += variants
        errors += int(failed)

    elapsed = time.monotonic() - started
    print("\nSummary")
    print(f"pass@10: {passed_puzzles}/{puzzle_count}")
    print(f"valid JSON: {valid_variants}/{total_variants}")
    print(f"errors: {errors}/{puzzle_count}")
    print(f"elapsed: {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
