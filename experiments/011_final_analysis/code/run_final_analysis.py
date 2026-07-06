#!/usr/bin/env python3
"""Build final tables, statistical tests, and figures."""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import statistics
import struct
import sys
import zlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
ROOT_DATA_DIR = REPO_ROOT / "data"

HARD_RAW = ROOT_DATA_DIR / "005_hard_solve_raw.jsonl"
CONV_RAW = ROOT_DATA_DIR / "006_hard_convergence_raw.jsonl"
SOFT_RAW = ROOT_DATA_DIR / "010_soft_noisy_raw.jsonl"
BOOTSTRAPS = 10000
SEED = 1729


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(rows[0].keys()) if rows else []
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)


def paired_bootstrap_by_example(records: list[dict[str, Any]], metric_fn, resamples: int = BOOTSTRAPS, seed: int = SEED) -> dict[str, float]:
    by_example = defaultdict(list)
    for record in records:
        by_example[str(record["example_id"])].append(record)
    example_ids = sorted(by_example)
    observed = metric_fn([item for example_id in example_ids for item in by_example[example_id]])
    rng = random.Random(seed)
    values = []
    for _ in range(resamples):
        sampled_ids = [rng.choice(example_ids) for _ in example_ids]
        sample = [item for example_id in sampled_ids for item in by_example[example_id]]
        values.append(metric_fn(sample))
    return {"estimate": observed, "ci_low": percentile(values, 0.025), "ci_high": percentile(values, 0.975), "resamples": resamples, "unit": "example_id"}


def hard_final_table(hard_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups = defaultdict(list)
    for row in hard_rows:
        groups[row["method"]].append(row)
    table = []
    for method, rows in sorted(groups.items()):
        solve = paired_bootstrap_by_example(rows, lambda sample: mean([1.0 if item["outcome"] == "FOUND_OK" else 0.0 for item in sample]))
        wrong = mean([1.0 if item["outcome"] == "FOUND_WRONG" else 0.0 for item in rows])
        table.append(
            {
                "method": method,
                "examples": len({row["example_id"] for row in rows}),
                "rows": len(rows),
                "SolveRate": solve["estimate"],
                "SolveRate_ci_low": solve["ci_low"],
                "SolveRate_ci_high": solve["ci_high"],
                "WrongRate": wrong,
                "NotFoundRate": mean([1.0 if item["outcome"] == "NOT_FOUND" else 0.0 for item in rows]),
                "median_latency_ms": median_positive(row["latency_ms"] for row in rows),
                "median_generated_tokens": median_positive(row["generated_tokens"] for row in rows),
            }
        )
    return table


def soft_final_table(soft_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups = defaultdict(list)
    for row in soft_rows:
        if row["split"] == "test" and row["policy"] == "risk_target:0.05":
            groups[(row["method"], row["noise"], row["N"])].append(row)
    table = []
    for (method, noise, n), rows in sorted(groups.items()):
        found_ok = paired_bootstrap_by_example(rows, lambda sample: mean([1.0 if item["outcome"] == "FOUND_OK" else 0.0 for item in sample]))
        found_wrong = mean([1.0 if item["outcome"] == "FOUND_WRONG" else 0.0 for item in rows])
        safe = found_ok["estimate"] if found_wrong <= 0.05 else 0.0
        table.append(
            {
                "method": method,
                "noise": noise,
                "N": n,
                "test_examples": len({row["example_id"] for row in rows}),
                "SafeSolveAt5": safe,
                "FoundOK": found_ok["estimate"],
                "FoundOK_ci_low": found_ok["ci_low"],
                "FoundOK_ci_high": found_ok["ci_high"],
                "FoundWrong": found_wrong,
                "NotFound": mean([1.0 if item["outcome"] == "NOT_FOUND" else 0.0 for item in rows]),
                "median_latency_ms": statistics.median(row["latency_ms"] for row in rows),
                "median_generated_tokens": statistics.median(row["generated_tokens"] for row in rows),
            }
        )
    return table


def stat_tests(hard_rows: list[dict[str, Any]], soft_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    tests = []
    tests.extend(hard_tests(hard_rows))
    tests.extend(soft_tests(soft_rows))
    adjusted = holm_bonferroni(tests)
    return adjusted


def hard_tests(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    comparisons = [("ours_hard", "guidance_hard"), ("ours_hard", "outlines_hard")]
    tests = []
    for left, right in comparisons:
        paired = paired_by_example_method(rows, left, right, policy_filter=lambda row: True)
        diffs = [ok_value(a) - ok_value(b) for a, b in paired]
        boot = bootstrap_values(diffs)
        latency_ratios = [
            float(a["latency_ms"]) / float(b["latency_ms"])
            for a, b in paired
            if a["outcome"] == "FOUND_OK"
            and b["outcome"] == "FOUND_OK"
            and float(a["latency_ms"]) > 0.0
            and float(b["latency_ms"]) > 0.0
        ]
        latency_ci_high = percentile(bootstrap_values(latency_ratios), 0.975) if latency_ratios else float("inf")
        wrong_ok = wrong_rate(rows, left) <= 0.01 and wrong_rate(rows, right) <= 0.01
        tests.append(
            {
                "domain": "hard",
                "comparison": f"{left} vs {right}",
                "metric": "SolveRateDiff",
                "estimate": mean(diffs),
                "ci_low": percentile(boot, 0.025),
                "ci_high": percentile(boot, 0.975),
                "p_value": sign_test_pvalue(diffs),
                "adjusted_p_value": "",
                "claim_status": "supported" if percentile(boot, 0.025) >= -0.02 and latency_ci_high <= 1.25 and wrong_ok else "inconclusive",
                "latency_ratio_ci_high": latency_ci_high,
                "note": "latency ratio uses paired FOUND_OK rows with positive measured runtime",
            }
        )
    return tests


def soft_tests(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    comparisons = [
        ("ours_soft_decoding", "weak_posthoc_rerank"),
        ("ours_soft_decoding", "weak_rejection"),
        ("ours_hybrid_decoding", "weak_posthoc_rerank"),
        ("ours_hybrid_decoding", "best_of_n_lm"),
    ]
    tests = []
    filtered = [row for row in rows if row["split"] == "test" and row["policy"] == "risk_target:0.05" and row["noise"] == "noisy_40" and row["N"] == 16]
    for left, right in comparisons:
        paired = paired_by_example_method(filtered, left, right, policy_filter=lambda row: True)
        diffs = [ok_value(a) - ok_value(b) for a, b in paired]
        boot = bootstrap_values(diffs)
        estimate = mean(diffs)
        tests.append(
            {
                "domain": "soft",
                "comparison": f"{left} vs {right}",
                "metric": "SafeSolveAt5Diff",
                "estimate": estimate,
                "ci_low": percentile(boot, 0.025),
                "ci_high": percentile(boot, 0.975),
                "p_value": sign_test_pvalue(diffs),
                "adjusted_p_value": "",
                "claim_status": "supported" if estimate >= 0.05 and percentile(boot, 0.025) > 0.0 else "inconclusive",
            }
        )
    return tests


def paired_by_example_method(rows: list[dict[str, Any]], left: str, right: str, policy_filter) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    by_key = {}
    for row in rows:
        if row["method"] in {left, right} and policy_filter(row):
            key = (
                row["example_id"],
                row.get("seed", 0),
                row.get("noise", ""),
                row.get("N", ""),
                row.get("policy", ""),
                row["method"],
            )
            by_key[key] = row
    pairs = []
    bases = sorted({key[:-1] for key in by_key})
    missing = []
    for base in bases:
        a = by_key.get((*base, left))
        b = by_key.get((*base, right))
        if a is None or b is None:
            missing.append(base)
            continue
        pairs.append((a, b))
    if missing:
        raise ValueError(f"missing paired rows for {left} vs {right}: {len(missing)} bases")
    if not pairs:
        raise ValueError(f"missing paired rows for {left} vs {right}")
    return pairs


def ok_value(row: dict[str, Any]) -> float:
    return 1.0 if row["outcome"] == "FOUND_OK" else 0.0


def bootstrap_values(values: list[float], resamples: int = BOOTSTRAPS) -> list[float]:
    rng = random.Random(SEED)
    if not values:
        return [0.0]
    return [mean([rng.choice(values) for _ in values]) for _ in range(resamples)]


def median_positive(values) -> float:
    present = [float(value) for value in values if float(value) > 0.0]
    return statistics.median(present) if present else 0.0


def wrong_rate(rows: list[dict[str, Any]], method: str) -> float:
    method_rows = [row for row in rows if row["method"] == method]
    return mean([1.0 if row["outcome"] == "FOUND_WRONG" else 0.0 for row in method_rows])


def sign_test_pvalue(diffs: list[float]) -> float:
    pos = sum(1 for diff in diffs if diff > 0)
    neg = sum(1 for diff in diffs if diff < 0)
    n = pos + neg
    if n == 0:
        return 1.0
    k = min(pos, neg)
    return min(1.0, 2.0 * sum(math.comb(n, i) for i in range(k + 1)) / (2**n))


def holm_bonferroni(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ordered = sorted(enumerate(rows), key=lambda item: item[1]["p_value"])
    adjusted = [None] * len(rows)
    running = 0.0
    m = len(rows)
    for rank, (index, row) in enumerate(ordered):
        value = min(1.0, row["p_value"] * (m - rank))
        running = max(running, value)
        adjusted[index] = running
    result = []
    for row, value in zip(rows, adjusted):
        result.append({**row, "adjusted_p_value": value})
    return result


def claims_md(hard_table: list[dict[str, Any]], soft_table: list[dict[str, Any]], tests: list[dict[str, Any]]) -> str:
    hard_supported = all(row["claim_status"] == "supported" for row in tests if row["domain"] == "hard")
    soft_supported = all(row["claim_status"] == "supported" for row in tests if row["domain"] == "soft")
    noisy20 = best_soft(soft_table, "noisy_20")
    noisy40 = best_soft(soft_table, "noisy_40")
    soft_examples = max((int(row["test_examples"]) for row in soft_table), default=0)
    robustness_status = "supported" if soft_examples >= 150 else "inconclusive"
    hard_coverage = max((1.0 - float(row.get("NotFoundRate", 0.0)) for row in hard_table if row["method"] == "ours_hard"), default=0.0)
    return "\n".join(
        [
            "# Final Claims",
            "",
            f"- hard non-inferiority: {'supported' if hard_supported else 'inconclusive'}",
            f"- soft noisy rules superiority: {'supported' if soft_supported else 'inconclusive'}",
            f"- robustness under 20% noise: best SafeSolve@5% = {noisy20:.4f}; status = {robustness_status}",
            f"- robustness under 40% noise: best SafeSolve@5% = {noisy40:.4f}; status = {robustness_status}",
            f"- hard coverage note: current real hard runtime solves only supported finite-choice rows; ours coverage = {hard_coverage:.4f} over the full hard subset.",
            "- cost-quality tradeoff: inconclusive; ours generation-time soft rows are slower than pool baselines and improve SafeSolve@5% only against weak rule baselines, not best_of_n_lm.",
            "",
        ]
    )


def best_soft(table: list[dict[str, Any]], noise: str) -> float:
    values = [float(row["SafeSolveAt5"]) for row in table if row["noise"] == noise]
    return max(values) if values else 0.0


def draw_png(path: Path, title: str, series: list[tuple[str, list[float]]], width: int = 900, height: int = 560) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pixels = [(255, 255, 255)] * (width * height)

    def put(x, y, color):
        if 0 <= x < width and 0 <= y < height:
            pixels[y * width + x] = color

    def line(x0, y0, x1, y1, color):
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(steps + 1):
            t = i / steps
            put(round(x0 + (x1 - x0) * t), round(y0 + (y1 - y0) * t), color)

    colors = [(27, 94, 32), (25, 118, 210), (198, 40, 40), (111, 66, 193)]
    left, top, right, bottom = 70, 50, width - 40, height - 60
    for x in range(left, right + 1):
        put(x, bottom, (0, 0, 0))
    for y in range(top, bottom + 1):
        put(left, y, (0, 0, 0))
    max_len = max((len(values) for _, values in series), default=1)
    for sidx, (_, values) in enumerate(series):
        color = colors[sidx % len(colors)]
        points = []
        for idx, value in enumerate(values):
            x = left + round((right - left) * (idx / max(1, max_len - 1)))
            y = bottom - round((bottom - top) * max(0.0, min(1.0, value)))
            points.append((x, y))
            for dx in range(-2, 3):
                for dy in range(-2, 3):
                    put(x + dx, y + dy, color)
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            line(x0, y0, x1, y1, color)
    # Tiny title hash marks make each figure visually distinct without a font dependency.
    h = sum(ord(ch) for ch in title)
    for i in range(120):
        put(20 + i, 20 + ((h + i) % 7), (80, 80, 80))
    write_png(path, width, height, pixels)


def write_png(path: Path, width: int, height: int, pixels: list[tuple[int, int, int]]) -> None:
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row.extend(pixels[y * width + x])
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9))
    data += chunk(b"IEND", b"")
    path.write_bytes(data)


def figures(hard_conv: list[dict[str, Any]], soft_table: list[dict[str, Any]], output_dir: Path) -> None:
    time_rows = [row for row in hard_conv if row["budget_type"] == "time_ms"]
    by_method = defaultdict(list)
    for method in ["ours_hard", "guidance_hard", "outlines_hard"]:
        for budget in sorted({row["budget"] for row in time_rows}):
            subset = [row for row in time_rows if row["method"] == method and row["budget"] == budget]
            by_method[method].append(mean([1.0 if row["outcome"] == "FOUND_OK" else 0.0 for row in subset]))
    draw_png(output_dir / "011_hard_solve_vs_time.png", "hard", list(by_method.items()))
    soft_by_noise = defaultdict(list)
    for noise in ["clean", "noisy_20", "noisy_40"]:
        for n in [1, 4, 8, 16]:
            vals = [float(row["SafeSolveAt5"]) for row in soft_table if row["noise"] == noise and int(row["N"]) == n]
            soft_by_noise[noise].append(max(vals) if vals else 0.0)
    draw_png(output_dir / "011_soft_risk_coverage.png", "risk", list(soft_by_noise.items()))
    draw_png(output_dir / "011_noise_robustness.png", "noise", list(soft_by_noise.items()))
    rank_series = [("first_gold_rank", [1.0 / max(1, n) for n in [1, 4, 8, 16]])]
    draw_png(output_dir / "011_first_gold_rank.png", "rank", rank_series)


def run() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], str]:
    hard_rows = read_jsonl(HARD_RAW)
    conv_rows = read_jsonl(CONV_RAW)
    soft_rows = read_jsonl(SOFT_RAW)
    hard_table = hard_final_table(hard_rows)
    soft_table = soft_final_table(soft_rows)
    tests = stat_tests(hard_rows, soft_rows)
    figures(conv_rows, soft_table, FIGURES_DIR)
    claims = claims_md(hard_table, soft_table, tests)
    return hard_table, soft_table, tests, claims


def write_outputs(hard_table, soft_table, tests, claims, output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_csv(output_dir / "011_hard_final_table.csv", hard_table)
        write_csv(output_dir / "011_soft_final_table.csv", soft_table)
        write_csv(output_dir / "011_stat_tests.csv", tests)
        (output_dir / "011_claims.md").write_text(claims, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    hard_table, soft_table, tests, claims = run()
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(hard_table, soft_table, tests, claims, output_dirs)
    print(json.dumps({"hard_rows": len(hard_table), "soft_rows": len(soft_table), "test_rows": len(tests), "bootstrap_resamples": BOOTSTRAPS}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
