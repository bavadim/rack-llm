#!/usr/bin/env python3

import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


EXPERIMENT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = EXPERIMENT_DIR / "results"
DEFAULT_FILES = {
    "random-unique": RESULTS_DIR / "random-unique.jsonl",
    "baseline": RESULTS_DIR / "baseline.jsonl",
    "baseline-unique": RESULTS_DIR / "baseline-unique.jsonl",
    "rack-llm": RESULTS_DIR / "rack-llm.jsonl",
}
LEVELS = (2, 3, 4)


def load(path):
    with path.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def case_groups(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[row["case_id"]].append(row)
    return groups


def mode_metrics(rows, attempts):
    groups = case_groups(rows)
    solved_at_1 = 0
    solved_at_k = 0
    valid = 0
    unique = 0
    case_times = []
    costs = []

    for candidates in groups.values():
        solved_at_1 += any(
            row.get("attempt") == 1 and row["passed"] for row in candidates
        )
        solved_at_k += any(row["passed"] for row in candidates)
        valid += sum(row["valid"] for row in candidates)
        unique += len({row.get("output") for row in candidates if row["valid"]})
        mode = candidates[0]["mode"]
        if mode == "baseline":
            case_times.append(sum(row["elapsed_seconds"] for row in candidates))
            costs.append(max(row.get("request_number", 0) for row in candidates))
        elif mode == "baseline-unique":
            case_times.append(
                max(
                    row.get("case_elapsed_seconds", row["elapsed_seconds"])
                    for row in candidates
                )
            )
            costs.append(
                max(
                    row.get(
                        "case_request_count",
                        row.get("request_number", 0),
                    )
                    for row in candidates
                )
            )
        elif mode == "rack-llm":
            case_times.append(max(row["elapsed_seconds"] for row in candidates))
            costs.append(max(row.get("oracle_calls", 0) for row in candidates))
        else:
            case_times.append(0.0)
            costs.append(0)

    return {
        "cases": len(groups),
        "pass1": solved_at_1,
        "passk": solved_at_k,
        "valid": valid,
        "requested": len(groups) * attempts,
        "unique": unique,
        "seconds": sum(case_times),
        "mean_seconds": statistics.mean(case_times) if case_times else 0.0,
        "calls": sum(costs),
        "mean_calls": statistics.mean(costs) if costs else 0.0,
    }


def wilson(successes, total):
    if total == 0:
        return (0.0, 0.0)
    z = 1.96
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    half = (
        z
        * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total))
        / denominator
    )
    return center - half, center + half


def format_table(all_rows, attempts):
    lines = [
        f"| Mode | pass@1 | pass@{attempts} | Valid | Unique | Calls | Time |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    metrics = {}
    for mode, rows in all_rows.items():
        metric = mode_metrics(rows, attempts)
        metrics[mode] = metric
        lines.append(
            f"| {mode} | {metric['pass1']}/{metric['cases']} | "
            f"{metric['passk']}/{metric['cases']} | "
            f"{metric['valid']}/{metric['requested']} | "
            f"{metric['unique']}/{metric['requested']} | "
            f"{metric['calls']} | {metric['seconds']:.1f}s |"
        )
    return lines, metrics


def report(all_rows, attempts):
    lines = [
        "# Mini-Sudoku 4x4 Results",
        "",
        "Thirty uniquely solvable puzzles: ten each with 2, 3, and 4 blanks.",
        "",
        "Protocol: Qwen3-1.7B Q4_K_M through llama.cpp's native Completion "
        "endpoint with the Qwen ChatML template and thinking disabled, "
        "temperature 0.8, deterministic per-case seeds, ten requested "
        "candidates, and top-64 token probabilities for rack-llm.",
        "",
        "Server: NVIDIA GeForce GTX 1650 4 GB, Intel Core i7-9750H, "
        "context 8192, one slot, full GPU offload, and flash attention.",
        "",
        "## Overall",
        "",
    ]
    table, metrics = format_table(all_rows, attempts)
    lines.extend(table)
    expected_random = sum(
        10 * attempts / (4**missing) for missing in LEVELS
    )
    solved_cases = {
        mode: sorted({row["case_id"] for row in rows if row["passed"]})
        for mode, rows in all_rows.items()
    }
    model_solved_sets = {
        tuple(solved_cases[mode])
        for mode in ("baseline", "baseline-unique", "rack-llm")
        if mode in solved_cases
    }
    if len(model_solved_sets) == 1:
        solved_comparison = (
            "- All model-backed modes solved the same puzzle set. This suggests "
            "the result comes from a narrow model capability rather than from "
            "the resampling strategy."
        )
    else:
        solved_comparison = (
            "- The model-backed modes solved different puzzle IDs, which is "
            "consistent with a noisy low-probability search."
        )
    rack_score = metrics["rack-llm"]["passk"]
    random_score = metrics["random-unique"]["passk"]
    unique_score = metrics["baseline-unique"]["passk"]
    if rack_score > random_score and rack_score > unique_score:
        comparison = (
            f"- `rack-llm` solved {rack_score}/30, compared with "
            f"{random_score}/30 for random unique enumeration and "
            f"{unique_score}/30 for ordinary unique resampling. This is an "
            "observed improvement in this run."
        )
        conclusion = (
            "- The result supports the hypothesis that rack-llm search can "
            "recover useful lower-probability answers more effectively than "
            "independent sampling on tasks the model can partially solve. "
            "The 30-puzzle sample is still too small for a strong statistical "
            "claim."
        )
    else:
        comparison = (
            f"- `rack-llm` solved {rack_score}/30, compared with "
            f"{random_score}/30 for random unique enumeration and "
            f"{unique_score}/30 for ordinary unique resampling. This run does "
            "not show an improvement over both controls."
        )
        conclusion = (
            "- This experiment confirms rack-llm's format and deduplication "
            "guarantees, but does not confirm an improvement in semantic "
            "puzzle solving."
        )

    lines.extend(["", "## By Difficulty", ""])
    for missing in LEVELS:
        lines.extend([f"### {missing} blanks", ""])
        subset = {
            mode: [row for row in rows if row["missing_count"] == missing]
            for mode, rows in all_rows.items()
        }
        table, _ = format_table(subset, attempts)
        lines.extend(table)
        lines.append("")

    lines.extend(["## Uncertainty", ""])
    for mode in ("baseline", "baseline-unique", "rack-llm"):
        if mode not in metrics:
            continue
        metric = metrics[mode]
        low, high = wilson(metric["passk"], metric["cases"])
        lines.append(
            f"- `{mode}` pass@{attempts}: "
            f"{metric['passk']}/{metric['cases']} "
            f"({metric['passk'] / metric['cases']:.1%}), "
            f"95% Wilson CI [{low:.1%}, {high:.1%}]."
        )

    lines.extend(
        [
            "",
            "## Result",
            "",
            f"- Ten unique random guesses are expected to solve approximately "
            f"{expected_random:.2f}/30 puzzles; the recorded random control "
            f"solved {metrics['random-unique']['passk']}/30.",
            comparison,
            f"- `rack-llm` used {metrics['rack-llm']['calls']} one-token oracle "
            f"calls and {metrics['rack-llm']['seconds']:.1f}s. "
            f"`baseline-unique` used {metrics['baseline-unique']['calls']} full "
            f"generation requests and {metrics['baseline-unique']['seconds']:.1f}s.",
            "- Call counts are not directly equivalent: each rack-llm call "
            "requests one token distribution, while each baseline call requests "
            "a complete answer.",
            solved_comparison,
            conclusion,
            "",
            "Solved cases:",
            "",
            *[
                f"- `{mode}`: {', '.join(cases) if cases else 'none'}"
                for mode, cases in solved_cases.items()
            ],
            "",
            "## Interpretation",
            "",
            "- `random-unique` measures the score obtainable by enumerating valid "
            "arrays without using the model.",
            "- `baseline` measures ten ordinary generations, including format "
            "errors and duplicates.",
            "- `baseline-unique` measures ordinary resampling until ten unique "
            "valid arrays are collected, capped at 100 requests per puzzle.",
            "- `rack-llm` measures ten unique grammar-valid arrays from one lazy "
            "search.",
            "- For unique modes, pass@1 refers to the first retained valid "
            "candidate, not necessarily the first model request.",
            "- A useful rack-llm result must beat `random-unique` and should be "
            "compared with `baseline-unique` together with calls and elapsed time.",
            "",
        ]
    )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    for mode, path in DEFAULT_FILES.items():
        parser.add_argument(f"--{mode}", type=Path, default=path)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--output", type=Path, default=RESULTS_DIR / "report.md")
    args = parser.parse_args()

    all_rows = {}
    for mode in DEFAULT_FILES:
        path = getattr(args, mode.replace("-", "_"))
        if not path.exists():
            parser.error(f"missing results file: {path}")
        rows = load(path)
        if rows:
            all_rows[mode] = rows

    text = report(all_rows, args.attempts).rstrip()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
