#!/usr/bin/env python3

import argparse
import itertools
import json
import random
import sys
import time
from pathlib import Path

from common import (
    DEFAULT_DATASET,
    case_seed,
    load_cases,
    print_summary,
    result_record,
    select_cases,
    write_record,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--missing", type=int, choices=(3, 4, 5))
    parser.add_argument("--index", type=int)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        cases = select_cases(
            load_cases(args.dataset),
            missing=args.missing,
            index=args.index,
            limit=args.limit,
        )
    except ValueError as error:
        parser.error(str(error))
    destination = args.output.open("w", encoding="utf-8") if args.output else None
    started = time.monotonic()
    records = []
    try:
        print(f"Running random unique control on {len(cases)} case(s)")
        for case_number, case in enumerate(cases, start=1):
            rng = random.Random(case_seed(case))
            candidates = list(
                itertools.product(range(1, 5), repeat=case["missing_count"])
            )
            rng.shuffle(candidates)
            print(
                f"\n[{case_number}/{len(cases)}] {case['id']} | "
                f"{case['missing_count']} missing"
            )
            for attempt, answer in enumerate(candidates[:args.attempts], start=1):
                output = json.dumps(answer, separators=(",", ":"))
                record = result_record(
                    case,
                    "random-unique",
                    attempt,
                    output,
                    0.0,
                )
                records.append(record)
                write_record(destination, record)
                print(
                    f"  [{attempt}/{args.attempts}] "
                    f"{'PASS' if record['passed'] else 'FAIL'}"
                )
    finally:
        if destination:
            destination.close()
    print_summary(records, args.attempts, time.monotonic() - started)
    return 0


if __name__ == "__main__":
    sys.exit(main())
