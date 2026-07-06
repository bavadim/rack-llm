#!/usr/bin/env python3
"""Build hard-solve convergence curves from Experiment 005 raw results."""

from __future__ import annotations

import argparse
import csv
import json
import math
import struct
import zlib
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
FIGURES_DIR = EXPERIMENT_DIR / "figures"
ROOT_DATA_DIR = REPO_ROOT / "data"

CONFIG_PATH = EXPERIMENT_DIR / "config.json"
SOURCE_RAW_PATH = ROOT_DATA_DIR / "005_hard_solve_raw.jsonl"

RAW_NAME = "006_hard_convergence_raw.jsonl"
TIME_CSV = "006_hard_solve_by_time.csv"
TOKENS_CSV = "006_hard_solve_by_tokens.csv"
ATTEMPTS_CSV = "006_hard_solve_by_attempts.csv"
TIME_PNG = "006_hard_solve_by_time.png"
TOKENS_PNG = "006_hard_solve_by_tokens.png"


def read_jsonl(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def budgeted_outcome(row: dict, budget_type: str, budget: float) -> tuple[str, bool]:
    resource = resource_value(row, budget_type)
    if row["outcome"] in {"FOUND_OK", "FOUND_WRONG"} and resource <= budget:
        return row["outcome"], False
    return "NOT_FOUND", True


def resource_value(row: dict, budget_type: str) -> float:
    if budget_type == "time_ms":
        return float(row["latency_ms"])
    if budget_type == "token_budget":
        return float(row["generated_tokens"])
    if budget_type == "attempt_budget":
        return float(row["attempts"])
    raise ValueError(f"unknown budget type: {budget_type}")


def build_raw(source_rows: list[dict], config: dict) -> list[dict]:
    methods = set(config["methods"])
    raw_rows = []
    for row in source_rows:
        if row["method"] not in methods:
            continue
        for budget_type in ["time_ms", "token_budget", "attempt_budget"]:
            for budget in config[budget_type]:
                outcome, stopped = budgeted_outcome(row, budget_type, budget)
                raw_rows.append(
                    {
                        "method": row["method"],
                        "example_id": row["example_id"],
                        "seed": row["seed"],
                        "budget_type": budget_type,
                        "budget": budget,
                        "resource_value": resource_value(row, budget_type),
                        "original_outcome": row["outcome"],
                        "outcome": outcome,
                        "stopped_by_budget": stopped,
                        "latency_ms": row["latency_ms"],
                        "generated_tokens": row["generated_tokens"],
                        "attempts": row["attempts"],
                    }
                )
    return raw_rows


def summarize(raw_rows: list[dict], budget_type: str) -> list[dict]:
    groups: dict[tuple[str, float], list[dict]] = defaultdict(list)
    for row in raw_rows:
        if row["budget_type"] == budget_type:
            groups[(row["method"], float(row["budget"]))].append(row)
    summary = []
    for (method, budget), rows in sorted(groups.items(), key=lambda item: (item[0][0], item[0][1])):
        total = len(rows)
        found_ok = sum(row["outcome"] == "FOUND_OK" for row in rows)
        found_wrong = sum(row["outcome"] == "FOUND_WRONG" for row in rows)
        not_found = sum(row["outcome"] == "NOT_FOUND" for row in rows)
        found_rows = [row for row in rows if row["outcome"] == "FOUND_OK"]
        summary.append(
            {
                "method": method,
                "budget_type": budget_type,
                "budget": budget,
                "total": total,
                "FOUND_OK": found_ok,
                "FOUND_WRONG": found_wrong,
                "NOT_FOUND": not_found,
                "SolveRate": found_ok / total if total else 0.0,
                "WrongRate": found_wrong / total if total else 0.0,
                "NotFoundRate": not_found / total if total else 0.0,
                "TimeToFoundOK": mean([row["latency_ms"] for row in found_rows]),
                "TokensToFoundOK": mean([row["generated_tokens"] for row in found_rows]),
                "AttemptsToFoundOK": mean([row["attempts"] for row in found_rows]),
                "seed_count": len({row["seed"] for row in rows}),
            }
        )
    return summary


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def write_outputs(raw_rows: list[dict], summaries: dict[str, list[dict]], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_jsonl(output_dir / RAW_NAME, raw_rows)
        write_csv(output_dir / TIME_CSV, summaries["time_ms"])
        write_csv(output_dir / TOKENS_CSV, summaries["token_budget"])
        write_csv(output_dir / ATTEMPTS_CSV, summaries["attempt_budget"])


def draw_line_chart(path: Path, rows: list[dict], title: str, x_label: str) -> None:
    width, height = 900, 560
    img = [[(255, 255, 255) for _ in range(width)] for _ in range(height)]
    margin_left, margin_right, margin_top, margin_bottom = 90, 30, 50, 80
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom
    methods = sorted({row["method"] for row in rows})
    budgets = sorted({float(row["budget"]) for row in rows})
    colors = {
        "ours_hard": (31, 119, 180),
        "guidance_hard": (44, 160, 44),
        "outlines_hard": (214, 39, 40),
        "vanilla_nucleus_posthoc": (127, 127, 127),
    }

    def px(budget: float) -> int:
        if len(budgets) == 1:
            return margin_left
        return int(margin_left + (budget - min(budgets)) / (max(budgets) - min(budgets)) * plot_w)

    def py(rate: float) -> int:
        return int(margin_top + (1.0 - rate) * plot_h)

    draw_line(img, margin_left, margin_top, margin_left, margin_top + plot_h, (0, 0, 0))
    draw_line(img, margin_left, margin_top + plot_h, margin_left + plot_w, margin_top + plot_h, (0, 0, 0))
    for tick in [0.0, 0.25, 0.5, 0.75, 1.0]:
        y = py(tick)
        draw_line(img, margin_left - 5, y, margin_left + plot_w, y, (220, 220, 220))
        draw_text(img, 15, y - 6, f"{tick:.2f}", (0, 0, 0))
    for budget in budgets:
        x = px(budget)
        draw_line(img, x, margin_top + plot_h, x, margin_top + plot_h + 5, (0, 0, 0))
        draw_text(img, x - 20, margin_top + plot_h + 12, compact_number(budget), (0, 0, 0))
    draw_text(img, margin_left + 10, 20, title, (0, 0, 0))
    draw_text(img, margin_left + plot_w // 2 - 50, height - 35, x_label, (0, 0, 0))
    draw_text(img, 10, 45, "SolveRate", (0, 0, 0))

    rows_by_method_budget = {
        (row["method"], float(row["budget"])): float(row["SolveRate"])
        for row in rows
    }
    for idx, method in enumerate(methods):
        points = [(px(budget), py(rows_by_method_budget[(method, budget)])) for budget in budgets]
        color = colors.get(method, (0, 0, 0))
        for (x1, y1), (x2, y2) in zip(points, points[1:]):
            draw_line(img, x1, y1, x2, y2, color, thickness=3)
        for x, y in points:
            draw_circle(img, x, y, 4, color)
        legend_y = margin_top + 20 + idx * 18
        draw_line(img, width - 250, legend_y + 6, width - 225, legend_y + 6, color, thickness=3)
        draw_text(img, width - 215, legend_y, method, (0, 0, 0))
    write_png(path, img)


def compact_number(value: float) -> str:
    if abs(value - int(value)) < 1e-9:
        return str(int(value))
    return f"{value:g}"


def draw_line(img, x1, y1, x2, y2, color, thickness=1):
    dx = abs(x2 - x1)
    dy = -abs(y2 - y1)
    sx = 1 if x1 < x2 else -1
    sy = 1 if y1 < y2 else -1
    err = dx + dy
    x, y = x1, y1
    while True:
        for ox in range(-(thickness // 2), thickness // 2 + 1):
            for oy in range(-(thickness // 2), thickness // 2 + 1):
                set_pixel(img, x + ox, y + oy, color)
        if x == x2 and y == y2:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x += sx
        if e2 <= dx:
            err += dx
            y += sy


def draw_circle(img, cx, cy, r, color):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                set_pixel(img, x, y, color)


FONT = {
    "0": ["111", "101", "101", "101", "111"],
    "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"],
    "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"],
    "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"],
    "7": ["111", "001", "010", "010", "010"],
    "8": ["111", "101", "111", "101", "111"],
    "9": ["111", "101", "111", "001", "111"],
    ".": ["0", "0", "0", "0", "1"],
    "_": ["000", "000", "000", "000", "111"],
    "-": ["000", "000", "111", "000", "000"],
    ":": ["0", "1", "0", "1", "0"],
    " ": ["0", "0", "0", "0", "0"],
}


def glyph(ch: str) -> list[str]:
    if ch in FONT:
        return FONT[ch]
    if ch.isalpha():
        return ["111", "101", "111", "101", "101"]
    return ["111", "001", "010", "000", "010"]


def draw_text(img, x, y, text, color):
    cursor = x
    for ch in text:
        bitmap = glyph(ch)
        for row_idx, row in enumerate(bitmap):
            for col_idx, bit in enumerate(row):
                if bit == "1":
                    set_pixel(img, cursor + col_idx, y + row_idx, color)
        cursor += max(len(line) for line in bitmap) + 2


def set_pixel(img, x, y, color):
    if 0 <= y < len(img) and 0 <= x < len(img[0]):
        img[y][x] = color


def write_png(path: Path, img) -> None:
    height = len(img)
    width = len(img[0])
    raw = bytearray()
    for row in img:
        raw.append(0)
        for r, g, b in row:
            raw.extend([r, g, b])
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    source_rows = read_jsonl(SOURCE_RAW_PATH)
    raw_rows = build_raw(source_rows, config)
    summaries = {
        "time_ms": summarize(raw_rows, "time_ms"),
        "token_budget": summarize(raw_rows, "token_budget"),
        "attempt_budget": summarize(raw_rows, "attempt_budget"),
    }
    output_dirs = [RESULTS_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(raw_rows, summaries, output_dirs)
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    draw_line_chart(FIGURES_DIR / TIME_PNG, summaries["time_ms"], "Hard Solve By Time", "time_ms")
    draw_line_chart(FIGURES_DIR / TOKENS_PNG, summaries["token_budget"], "Hard Solve By Tokens", "token_budget")
    print(
        json.dumps(
            {
                "raw_rows": len(raw_rows),
                "methods": config["methods"],
                "outputs": [str(path) for path in output_dirs] + [str(FIGURES_DIR)],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
