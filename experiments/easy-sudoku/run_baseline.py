#!/usr/bin/env python3

import argparse
import json
import sys
import time
from pathlib import Path

import requests

from common import (
    DEFAULT_DATASET,
    SYSTEM_PROMPT,
    case_seed,
    llama_completion_prompt,
    load_cases,
    print_summary,
    result_record,
    select_cases,
    user_prompt,
    write_record,
)


def generate(
    server_url,
    system_prompt,
    user_prompt,
    max_tokens,
    temperature,
    timeout,
    seed,
):
    response = requests.post(
        f"{server_url.rstrip('/')}/completion",
        json={
            "prompt": llama_completion_prompt(system_prompt, user_prompt),
            "n_predict": max_tokens,
            "temperature": temperature,
            "stream": False,
            "seed": seed,
            "top_k": 0,
            "top_p": 1.0,
            "min_p": 0.0,
            "cache_prompt": True,
            "stop": ["\n"],
        },
        timeout=timeout,
    )
    response.raise_for_status()
    return response.json()["content"]


def run_case(case, case_number, case_count, args, destination):
    print(
        f"\n[{case_number}/{case_count}] {case['id']} | "
        f"{case['missing_count']} missing"
    )
    records = []
    for attempt in range(1, args.attempts + 1):
        started = time.monotonic()
        try:
            output = generate(
                args.server_url,
                SYSTEM_PROMPT,
                user_prompt(case),
                args.max_tokens,
                args.temperature,
                args.timeout,
                case_seed(case, attempt),
            )
            elapsed = time.monotonic() - started
            record = result_record(
                case,
                "baseline",
                attempt,
                output,
                elapsed,
                request_number=attempt,
            )
        except (requests.RequestException, KeyError, TypeError) as error:
            elapsed = time.monotonic() - started
            record = {
                "case_id": case["id"],
                "missing_count": case["missing_count"],
                "mode": "baseline",
                "attempt": attempt,
                "error": str(error),
                "valid": False,
                "passed": False,
                "elapsed_seconds": elapsed,
            }
        records.append(record)
        write_record(destination, record)
        print(
            f"  [{attempt}/{args.attempts}] "
            f"{'PASS' if record['passed'] else 'FAIL'} | "
            f"{'valid' if record['valid'] else 'invalid'} | "
            f"{elapsed:.2f}s"
        )
        if args.show_output:
            print(record.get("output", record.get("error", "")))

    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--missing", type=int, choices=(3, 4, 5))
    parser.add_argument("--index", type=int)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--temperature", type=float, default=0.8)
    parser.add_argument("--server-url", default="http://127.0.0.1:8080")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--show-output", action="store_true")
    args = parser.parse_args()

    if args.index is not None and args.index < 0:
        parser.error("--index must be non-negative")
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    if args.attempts < 1:
        parser.error("--attempts must be positive")
    if args.max_tokens < 1:
        parser.error("--max-tokens must be positive")

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
            f"Running baseline on {len(cases)} case(s), "
            f"{args.attempts} independent attempts each"
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
