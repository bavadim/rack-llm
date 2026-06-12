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
    load_cases,
    parse_answer,
    print_summary,
    result_record,
    select_cases,
    user_prompt,
    write_record,
)
from run_baseline import generate


def run_case(case, case_number, case_count, args, destination):
    print(
        f"\n[{case_number}/{case_count}] {case['id']} | "
        f"{case['missing_count']} missing",
        flush=True,
    )
    records = []
    seen = set()
    invalid = 0
    duplicates = 0
    request_count = 0
    started = time.monotonic()

    for request_number in range(1, args.max_requests + 1):
        request_count = request_number
        try:
            output = generate(
                args.server_url,
                SYSTEM_PROMPT,
                user_prompt(case),
                args.max_tokens,
                args.temperature,
                args.timeout,
                case_seed(case, request_number),
            )
        except (requests.RequestException, KeyError, TypeError) as error:
            print(f"  request {request_number}: ERROR | {error}")
            continue

        valid, answer = parse_answer(output, case["missing_count"])
        if not valid:
            invalid += 1
            continue
        key = tuple(answer)
        if key in seen:
            duplicates += 1
            continue

        seen.add(key)
        attempt = len(records) + 1
        elapsed = time.monotonic() - started
        record = result_record(
            case,
            "baseline-unique",
            attempt,
            output,
            elapsed,
            request_number=request_number,
        )
        records.append(record)
        print(
            f"  [{attempt}/{args.attempts}] "
            f"{'PASS' if record['passed'] else 'FAIL'} | "
            f"request {request_number}"
        )
        if args.show_output:
            print(output)
        if len(records) == args.attempts:
            break

    elapsed = time.monotonic() - started
    for record in records:
        record["case_request_count"] = request_count
        record["case_elapsed_seconds"] = elapsed
        write_record(destination, record)
    print(
        f"  produced {len(records)}/{args.attempts} unique valid outputs "
        f"in {elapsed:.1f}s | invalid {invalid} | duplicates {duplicates}"
    )
    if not records:
        record = {
            "case_id": case["id"],
            "missing_count": case["missing_count"],
            "mode": "baseline-unique",
            "error": "no unique valid outputs",
            "valid": False,
            "passed": False,
            "elapsed_seconds": elapsed,
            "request_number": args.max_requests,
            "case_request_count": request_count,
            "case_elapsed_seconds": elapsed,
        }
        write_record(destination, record)
        return [record]
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--missing", type=int, choices=(3, 4, 5))
    parser.add_argument("--index", type=int)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--max-requests", type=int, default=100)
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
    if args.attempts < 1 or args.max_requests < args.attempts:
        parser.error("--max-requests must be at least --attempts")

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

    destination = args.output.open("w", encoding="utf-8") if args.output else None
    started = time.monotonic()
    records = []
    try:
        print(
            f"Running unique baseline on {len(cases)} case(s), "
            f"{args.attempts} unique valid outputs, "
            f"at most {args.max_requests} requests each"
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
