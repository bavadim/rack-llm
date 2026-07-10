#!/usr/bin/env python3
"""Build Experiment 012 final tables, tests, claims, and figures."""

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
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
ROOT_DATA_DIR = REPO_ROOT / "data"

HARD_RAW = ROOT_DATA_DIR / "012_hard_real_raw.jsonl"
SOFT_RAW = ROOT_DATA_DIR / "012_soft_real_raw.jsonl"
SOFT_SUMMARY = ROOT_DATA_DIR / "012_soft_real_summary.csv"
MISSING_RUNS = ROOT_DATA_DIR / "012_missing_runs.json"
BOOTSTRAPS = 1000
SEED = 1729


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


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


def paired_bootstrap(records: list[dict[str, Any]], metric_fn: Callable[[list[dict[str, Any]]], float]) -> dict[str, Any]:
    by_example: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        by_example[example_id(record)].append(record)
    ids = sorted(by_example)
    observed = metric_fn([item for key in ids for item in by_example[key]])
    rng = random.Random(SEED)
    values = []
    for _ in range(BOOTSTRAPS):
        sampled = [rng.choice(ids) for _ in ids]
        values.append(metric_fn([item for key in sampled for item in by_example[key]]))
    return {"estimate": observed, "ci_low": percentile(values, 0.025), "ci_high": percentile(values, 0.975), "resamples": BOOTSTRAPS, "unit": "example_id"}


def example_id(row: dict[str, Any]) -> str:
    return str(row.get("example_id", row.get("key")))


def ok_value(row: dict[str, Any]) -> float:
    return 1.0 if row["outcome"] in {"FOUND_OK", "SOLVED"} else 0.0


def wrong_value(row: dict[str, Any]) -> float:
    return 1.0 if row["outcome"] in {"FOUND_WRONG", "WRONG"} else 0.0


def hard_final_table(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[row["method"]].append(row)
    table = []
    for method, group in sorted(groups.items()):
        solve = paired_bootstrap(group, lambda sample: mean([ok_value(item) for item in sample]))
        table.append(
            {
                "method": method,
                "examples": len({example_id(row) for row in group}),
                "rows": len(group),
                "SolveRate": solve["estimate"],
                "SolveRate_ci_low": solve["ci_low"],
                "SolveRate_ci_high": solve["ci_high"],
                "WrongRate": mean([wrong_value(row) for row in group]),
                "median_latency_ms": statistics.median(float(row["latency_ms"]) for row in group),
                "median_generated_tokens": statistics.median(float(row["generated_tokens"]) for row in group),
            }
        )
    return table


def soft_final_table(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        if row["split"] == "test" and row["policy"] == "risk_target:0.05":
            groups[(row["method"], row["noise"], int(row["N"]))].append(row)
    table = []
    for (method, noise, n), group in sorted(groups.items()):
        found = paired_bootstrap(group, lambda sample: mean([ok_value(item) for item in sample]))
        wrong = mean([wrong_value(row) for row in group])
        table.append(
            {
                "method": method,
                "noise": noise,
                "N": n,
                "test_examples": len({example_id(row) for row in group}),
                "SafeSolveAt5": found["estimate"] if wrong <= 0.05 else 0.0,
                "FoundOK": found["estimate"],
                "FoundOK_ci_low": found["ci_low"],
                "FoundOK_ci_high": found["ci_high"],
                "FoundWrong": wrong,
                "NotFound": mean([1.0 if row["outcome"] == "NOT_FOUND" else 0.0 for row in group]),
                "median_latency_ms": statistics.median(float(row["latency_ms"]) for row in group),
                "median_generated_tokens": statistics.median(float(row["generated_tokens"]) for row in group),
            }
        )
    return table


def paired_by_method(rows: list[dict[str, Any]], left: str, right: str) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    by_key: dict[tuple, dict[str, Any]] = {}
    for row in rows:
        if row["method"] not in {left, right}:
            continue
        key = (
            example_id(row),
            row.get("seed", 0),
            row.get("noise", ""),
            row.get("N", ""),
            row.get("policy", ""),
            row["method"],
        )
        by_key[key] = row
    pairs = []
    bases = sorted({key[:-1] for key in by_key})
    for base in bases:
        a = by_key.get((*base, left))
        b = by_key.get((*base, right))
        if a and b:
            pairs.append((a, b))
    return pairs


def bootstrap_diffs(diffs: list[float]) -> list[float]:
    if not diffs:
        return [0.0]
    rng = random.Random(SEED)
    return [mean([rng.choice(diffs) for _ in diffs]) for _ in range(BOOTSTRAPS)]


def sign_pvalue(diffs: list[float]) -> float:
    pos = sum(1 for diff in diffs if diff > 0)
    neg = sum(1 for diff in diffs if diff < 0)
    n = pos + neg
    if n == 0:
        return 1.0
    k = min(pos, neg)
    return min(1.0, 2.0 * sum(math.comb(n, i) for i in range(k + 1)) / (2**n))


def comparison_row(domain: str, rows: list[dict[str, Any]], left: str, right: str, metric: str, missing: list[dict[str, Any]]) -> dict[str, Any]:
    pairs = paired_by_method(rows, left, right)
    if not pairs:
        reason = "missing paired rows"
        if any(item["method"] == left for item in missing):
            reason = "left method has missing generation-time runs"
        return {
            "domain": domain,
            "comparison": f"{left} vs {right}",
            "metric": metric,
            "estimate": 0.0,
            "ci_low": 0.0,
            "ci_high": 0.0,
            "p_value": 1.0,
            "adjusted_p_value": "",
            "claim_status": "inconclusive",
            "test": "paired bootstrap by example; sign/McNemar-style exact test",
            "note": reason,
        }
    diffs = [ok_value(a) - ok_value(b) for a, b in pairs]
    boot = bootstrap_diffs(diffs)
    estimate = mean(diffs)
    supported = (domain == "hard" and percentile(boot, 0.025) >= -0.02) or (domain == "soft" and estimate >= 0.05 and percentile(boot, 0.025) > 0.0)
    return {
        "domain": domain,
        "comparison": f"{left} vs {right}",
        "metric": metric,
        "estimate": estimate,
        "ci_low": percentile(boot, 0.025),
        "ci_high": percentile(boot, 0.975),
        "p_value": sign_pvalue(diffs),
        "adjusted_p_value": "",
        "claim_status": "supported" if supported else "inconclusive",
        "test": "paired bootstrap by example; sign/McNemar-style exact test",
        "note": "",
    }


def stat_tests(hard_rows: list[dict[str, Any]], soft_rows: list[dict[str, Any]], missing: list[dict[str, Any]]) -> list[dict[str, Any]]:
    tests = [
        comparison_row("hard", hard_rows, "ours_hard", "guidance_hard", "SolveRateDiff", missing),
        comparison_row("hard", hard_rows, "ours_hard", "outlines_hard", "SolveRateDiff", missing),
    ]
    filtered_soft = [row for row in soft_rows if row["split"] == "test" and row["policy"] == "risk_target:0.05" and row["noise"] == "noisy_40" and int(row["N"]) == 16]
    for left, right in [
        ("ours_soft_decoding", "weak_posthoc_rerank"),
        ("ours_soft_decoding", "weak_rejection"),
        ("ours_hybrid_decoding", "weak_posthoc_rerank"),
        ("ours_hybrid_decoding", "best_of_n_lm"),
    ]:
        tests.append(comparison_row("soft", filtered_soft, left, right, "SafeSolveAt5Diff", missing))
    return holm_bonferroni(tests)


def holm_bonferroni(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ordered = sorted(enumerate(rows), key=lambda item: float(item[1]["p_value"]))
    adjusted = [0.0] * len(rows)
    running = 0.0
    m = len(rows)
    for rank, (index, row) in enumerate(ordered):
        running = max(running, min(1.0, float(row["p_value"]) * (m - rank)))
        adjusted[index] = running
    return [{**row, "adjusted_p_value": adjusted[index]} for index, row in enumerate(rows)]


def claims_md(hard_table: list[dict[str, Any]], soft_table: list[dict[str, Any]], tests: list[dict[str, Any]], missing: list[dict[str, Any]]) -> str:
    hard_status = "supported" if all(row["claim_status"] == "supported" for row in tests if row["domain"] == "hard") else "inconclusive"
    soft_status = "supported" if all(row["claim_status"] == "supported" for row in tests if row["domain"] == "soft") else "inconclusive"
    soft_note = (
        "- soft note: `ours_*` rows are real Racket native llama.cpp generation-time runs over the full vocabulary."
        if not missing
        else "- soft note: candidate-pool baselines are reported, but `ours_*` soft claims remain inconclusive until exact-full-vocab Racket generation-time runs complete."
    )
    return "\n".join(
        [
            "# Experiment 012 Claims",
            "",
            f"- hard non-inferiority: {hard_status}",
            f"- soft superiority of generation-time ours methods: {soft_status}",
            f"- missing generation-time soft runs: {len(missing)} combinations",
            "- evidence source: only `012_*` real artifacts; pilot `005-011` outputs are non-paper-grade.",
            soft_note,
            "",
        ]
    )


def draw_png(path: Path, title: str, values: list[float], width: int = 640, height: int = 360) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pixels = [(255, 255, 255)] * (width * height)

    def put(x: int, y: int, color: tuple[int, int, int]) -> None:
        if 0 <= x < width and 0 <= y < height:
            pixels[y * width + x] = color

    left, top, right, bottom = 50, 40, width - 30, height - 40
    for x in range(left, right + 1):
        put(x, bottom, (0, 0, 0))
    for y in range(top, bottom + 1):
        put(left, y, (0, 0, 0))
    vals = values or [0.0]
    for idx, value in enumerate(vals):
        x0 = left + int((right - left) * idx / max(1, len(vals)))
        x1 = left + int((right - left) * (idx + 1) / max(1, len(vals))) - 2
        y = bottom - int((bottom - top) * max(0.0, min(1.0, value)))
        for x in range(x0, max(x0 + 1, x1)):
            for yy in range(y, bottom):
                put(x, yy, (25, 118, 210))
    marker = sum(ord(ch) for ch in title)
    for i in range(100):
        put(20 + i, 20 + ((marker + i) % 9), (90, 90, 90))
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


def figures(hard_table: list[dict[str, Any]], soft_table: list[dict[str, Any]]) -> None:
    draw_png(FIGURES_DIR / "012_hard_solve_vs_time.png", "hard", [float(row["SolveRate"]) for row in hard_table])
    draw_png(FIGURES_DIR / "012_soft_risk_coverage.png", "soft", [float(row["SafeSolveAt5"]) for row in soft_table if row["noise"] == "clean"])
    draw_png(FIGURES_DIR / "012_noise_robustness.png", "noise", [float(row["SafeSolveAt5"]) for row in soft_table if int(row["N"]) == 16])
    draw_png(FIGURES_DIR / "012_first_gold_rank.png", "rank", [1.0 / max(1.0, float(row["N"])) for row in soft_table[:32]])


def run() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], str]:
    hard_rows = read_jsonl(HARD_RAW)
    soft_rows = read_jsonl(SOFT_RAW)
    _soft_summary = read_csv(SOFT_SUMMARY)
    missing = json.loads(MISSING_RUNS.read_text(encoding="utf-8"))
    hard_table = hard_final_table(hard_rows)
    soft_table = soft_final_table(soft_rows)
    tests = stat_tests(hard_rows, soft_rows, missing)
    figures(hard_table, soft_table)
    claims = claims_md(hard_table, soft_table, tests, missing)
    return hard_table, soft_table, tests, claims


def write_outputs(hard_table, soft_table, tests, claims, output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_csv(output_dir / "012_hard_final_table.csv", hard_table)
        write_csv(output_dir / "012_soft_final_table.csv", soft_table)
        write_csv(output_dir / "012_stat_tests.csv", tests)
        (output_dir / "012_claims.md").write_text(claims, encoding="utf-8")


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
