#!/usr/bin/env python3

import json
import zlib
from pathlib import Path


EXPERIMENT_DIR = Path(__file__).resolve().parent
DEFAULT_DATASET = EXPERIMENT_DIR / "dataset.jsonl"

SYSTEM_PROMPT = """Solve the 4 by 4 mini-Sudoku completion task.
Return only a JSON array of digits in the requested cell order.
Use numbers without quotes, for example: [2,4,1]
Do not explain the answer and do not use Markdown."""


def load_cases(path=DEFAULT_DATASET):
    with Path(path).open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def select_cases(cases, missing=None, index=None, limit=None):
    selected = [
        case for case in cases
        if missing is None or case["missing_count"] == missing
    ]
    if index is not None:
        if index >= len(selected):
            raise ValueError(
                f"index {index} is out of range; available: 0..{len(selected) - 1}"
            )
        selected = [selected[index]]
    if limit is not None:
        selected = selected[:limit]
    return selected


def case_seed(case, offset=0):
    return (
        20260612 + zlib.crc32(case["id"].encode("ascii")) + offset
    ) % (2**31 - 1)


def user_prompt(case):
    grid = "\n".join(case["puzzle"])
    cells = ", ".join(case["cells"])
    return f"""This grid has exactly {case["missing_count"]} dots.
Each row, column, and 2 by 2 box contains digits 1, 2, 3, 4 exactly once.
Find only the digits replacing those dots.
Return exactly {case["missing_count"]} numbers, in the listed cell order.
Do not return completed rows.

Grid:
{grid}

Cells: {cells}
Answer:"""


def llama_completion_prompt(system_prompt, prompt):
    return f"system: {system_prompt}\nuser: {prompt}"


def parse_answer(output, expected_length):
    try:
        answer = json.loads(output.strip())
    except (json.JSONDecodeError, AttributeError):
        return False, []
    valid = (
        isinstance(answer, list)
        and len(answer) == expected_length
        and all(type(digit) is int and 1 <= digit <= 4 for digit in answer)
    )
    return valid, answer if valid else []


def check_answer(case, answer):
    return answer == case["answer"]


def result_record(case, mode, attempt, output, elapsed, **extra):
    valid, answer = parse_answer(output, case["missing_count"])
    record = {
        "case_id": case["id"],
        "missing_count": case["missing_count"],
        "mode": mode,
        "attempt": attempt,
        "output": output,
        "valid": valid,
        "passed": valid and check_answer(case, answer),
        "elapsed_seconds": elapsed,
    }
    record.update(extra)
    return record


def write_record(destination, record):
    if destination is None:
        return
    destination.write(json.dumps(record, ensure_ascii=True) + "\n")
    destination.flush()


def summary_rows(records, attempts):
    rows = []
    levels = sorted({record["missing_count"] for record in records})
    for label, level in [("overall", None), *[(str(value), value) for value in levels]]:
        selected = [
            record for record in records
            if level is None or record["missing_count"] == level
        ]
        case_ids = sorted({record["case_id"] for record in selected})
        first_passes = {
            record["case_id"]
            for record in selected
            if record.get("attempt") == 1 and record["passed"]
        }
        any_passes = {
            record["case_id"] for record in selected if record["passed"]
        }
        rows.append(
            {
                "level": label,
                "cases": len(case_ids),
                "pass_at_1": len(first_passes),
                "pass_at_k": len(any_passes),
                "attempts": attempts,
                "valid": sum(record["valid"] for record in selected),
                "requested": len(case_ids) * attempts,
                "errors": sum("error" in record for record in selected),
            }
        )
    return rows


def print_summary(records, attempts, elapsed):
    print("\nSummary")
    for row in summary_rows(records, attempts):
        metrics = [f"pass@1 {row['pass_at_1']}/{row['cases']}"]
        if attempts != 1:
            metrics.append(
                f"pass@{attempts} {row['pass_at_k']}/{row['cases']}"
            )
        metrics.extend(
            (
                f"valid {row['valid']}/{row['requested']}",
                f"errors {row['errors']}",
            )
        )
        print(f"{row['level']:>7}: {' | '.join(metrics)}")
    print(f"elapsed: {elapsed:.1f}s")
