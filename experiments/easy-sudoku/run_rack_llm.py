#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from common import (
    DEFAULT_DATASET,
    SYSTEM_PROMPT,
    case_seed,
    load_cases,
    print_summary,
    result_record,
    select_cases,
    user_prompt,
    write_record,
)


EXPERIMENT_DIR = Path(__file__).resolve().parent
RACKET_PROGRAM = EXPERIMENT_DIR / "rack_llm_sample.rkt"


def run_case(case, case_number, case_count, args, destination):
    print(
        f"\n[{case_number}/{case_count}] {case['id']} | "
        f"{case['missing_count']} missing",
        flush=True,
    )
    request = {
        "system_prompt": SYSTEM_PROMPT,
        "user_prompt": user_prompt(case),
        "answer_length": case["missing_count"],
        "variants": args.attempts,
        "n_probs": args.n_probs,
        "temperature": args.temperature,
        "server_url": args.server_url,
        "seed": case_seed(case),
    }
    started = time.monotonic()
    try:
        process = subprocess.run(
            ["racket", str(RACKET_PROGRAM)],
            input=json.dumps(request),
            stdout=subprocess.PIPE,
            text=True,
            timeout=args.timeout,
            env=os.environ.copy(),
        )
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - started
        print(f"  TIMEOUT after {elapsed:.1f}s")
        record = {
            "case_id": case["id"],
            "missing_count": case["missing_count"],
            "mode": "rack-llm",
            "error": f"timeout after {args.timeout}s",
            "valid": False,
            "passed": False,
            "elapsed_seconds": elapsed,
        }
        write_record(destination, record)
        return [record]

    elapsed = time.monotonic() - started
    if process.returncode != 0:
        print(f"  ERROR | Racket exited with {process.returncode}")
        record = {
            "case_id": case["id"],
            "missing_count": case["missing_count"],
            "mode": "rack-llm",
            "error": f"Racket exited with {process.returncode}",
            "valid": False,
            "passed": False,
            "elapsed_seconds": elapsed,
        }
        write_record(destination, record)
        return [record]

    try:
        response = json.loads(process.stdout)
        outputs = response["outputs"]
        oracle_calls = response["oracle_calls"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"  ERROR | invalid Racket output: {error}")
        record = {
            "case_id": case["id"],
            "missing_count": case["missing_count"],
            "mode": "rack-llm",
            "error": f"invalid Racket output: {error}",
            "valid": False,
            "passed": False,
            "elapsed_seconds": elapsed,
        }
        write_record(destination, record)
        return [record]

    if not outputs:
        print("  ERROR | rack-llm stream produced no variants")
        record = {
            "case_id": case["id"],
            "missing_count": case["missing_count"],
            "mode": "rack-llm",
            "error": "rack-llm stream produced no variants",
            "valid": False,
            "passed": False,
            "elapsed_seconds": elapsed,
        }
        write_record(destination, record)
        return [record]

    records = []
    for attempt, output in enumerate(outputs, start=1):
        record = result_record(
            case,
            "rack-llm",
            attempt,
            output,
            elapsed,
            oracle_calls=oracle_calls,
        )
        records.append(record)
        write_record(destination, record)
        print(
            f"  [{attempt}/{len(outputs)}] "
            f"{'PASS' if record['passed'] else 'FAIL'} | "
            f"{'valid' if record['valid'] else 'invalid'}"
        )
        if args.show_output:
            print(output)

    print(f"  produced {len(outputs)}/{args.attempts} variants | {elapsed:.1f}s")
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--missing", type=int, choices=(2, 3, 4))
    parser.add_argument("--index", type=int)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--n-probs", type=int, default=64)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--server-url", default="http://127.0.0.1:8080")
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--show-output", action="store_true")
    args = parser.parse_args()

    if args.index is not None and args.index < 0:
        parser.error("--index must be non-negative")
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    if args.attempts < 1:
        parser.error("--attempts must be positive")
    if args.n_probs < 1:
        parser.error("--n-probs must be positive")

    try:
        cases = select_cases(
            load_cases(args.dataset),
            missing=args.missing,
            index=args.index,
            limit=args.limit,
        )
    except ValueError as error:
        parser.error(str(error))
    if not cases:
        parser.error("no cases selected")

    destination = (
        args.output.open("w", encoding="utf-8") if args.output else None
    )
    started = time.monotonic()
    records = []
    try:
        print(
            f"Running rack-llm on {len(cases)} case(s), "
            f"up to {args.attempts} unique variants each"
        )
        for case_number, case in enumerate(cases, start=1):
            records.extend(
                run_case(case, case_number, len(cases), args, destination)
            )
    finally:
        if destination:
            destination.close()

    print_summary(records, args.attempts, time.monotonic() - started)
    return 0


if __name__ == "__main__":
    sys.exit(main())
