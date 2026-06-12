#!/usr/bin/env python3

import argparse
import json
import re
import sys
import time
from pathlib import Path

import requests

from ppbench import Puzzle
from ppbench.benchmarks.strategies.direct_ask import (
    example_of_inputs,
    get_example_move_context,
    get_rules_for_puzzle,
)


SERVER_URL = "http://127.0.0.1:8080"
EXPERIMENT_DIR = Path(__file__).resolve().parent
DATASET_PATH = EXPERIMENT_DIR / "dataset.jsonl"


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


def generate(system_prompt, user_prompt, max_tokens):
    response = requests.post(
        f"{SERVER_URL}/v1/chat/completions",
        json={
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.8,
            "max_tokens": max_tokens,
        },
        timeout=600,
    )
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


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


def run_puzzle(record, puzzle_number, puzzle_count, args):
    puzzle = Puzzle.from_url(record["puzzlink_url"])
    system_prompt, user_prompt = prompts(puzzle)
    valid_attempts = 0
    solved_attempts = 0
    error_attempts = 0

    print(
        f"\n[{puzzle_number}/{puzzle_count}] "
        f"{record['pid']} | {record['puzzlink_url']}"
    )

    for attempt in range(1, args.attempts + 1):
        started = time.monotonic()
        try:
            output = generate(system_prompt, user_prompt, args.max_tokens)
            valid_json, moves = parse_moves(output)
            passed = valid_json and check_moves(record["puzzlink_url"], moves)
        except (requests.RequestException, KeyError, IndexError, TypeError) as error:
            error_attempts += 1
            print(f"  [{attempt}/{args.attempts}] ERROR | {error}")
            continue

        elapsed = time.monotonic() - started
        valid_attempts += int(valid_json)
        solved_attempts += int(passed)
        print(
            f"  [{attempt}/{args.attempts}] "
            f"{'PASS' if passed else 'FAIL'} | "
            f"JSON: {'valid' if valid_json else 'invalid'} | "
            f"{len(moves)} moves | {elapsed:.1f}s"
        )
        if args.show_output:
            print(output)

    passed = solved_attempts > 0
    print(
        f"  pass@{args.attempts}: {int(passed)} | "
        f"valid JSON: {valid_attempts}/{args.attempts}"
    )
    return passed, valid_attempts, error_attempts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--puzzle-type")
    parser.add_argument("--index", type=int)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--show-output", action="store_true")
    args = parser.parse_args()

    if args.attempts < 1:
        parser.error("--attempts must be at least 1")
    if args.max_tokens < 1:
        parser.error("--max-tokens must be at least 1")
    if args.index is not None and args.index < 0:
        parser.error("--index must be non-negative")

    records = select_records(args.puzzle_type, args.index)
    total_puzzles = len(records)
    total_attempts = total_puzzles * args.attempts
    passed_puzzles = 0
    valid_attempts = 0
    error_attempts = 0
    started = time.monotonic()

    print(
        f"Running baseline on {total_puzzles} puzzle(s), "
        f"{args.attempts} attempts each"
    )
    for puzzle_number, record in enumerate(records, start=1):
        passed, valid, errors = run_puzzle(
            record, puzzle_number, total_puzzles, args
        )
        passed_puzzles += int(passed)
        valid_attempts += valid
        error_attempts += errors

    elapsed = time.monotonic() - started
    print("\nSummary")
    print(f"pass@{args.attempts}: {passed_puzzles}/{total_puzzles}")
    print(f"valid JSON: {valid_attempts}/{total_attempts}")
    print(f"errors: {error_attempts}/{total_attempts}")
    print(f"elapsed: {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
