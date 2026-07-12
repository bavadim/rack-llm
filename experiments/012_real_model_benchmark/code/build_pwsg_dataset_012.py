#!/usr/bin/env python3
"""Build the portable structural PWSG rule templates for Experiment 012."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE = REPO_ROOT / "data" / "soft_ifbench_rules.jsonl"
OUTPUT = REPO_ROOT / "data" / "012_pwsg_specs.jsonl"
RESULT_OUTPUT = REPO_ROOT / "experiments" / "012_real_model_benchmark" / "results" / "012_pwsg_specs.jsonl"

STOP = {
    "about", "after", "again", "answer", "before", "could", "exactly", "from",
    "have", "into", "must", "only", "please", "response", "should", "their",
    "there", "these", "they", "this", "using", "what", "when", "where", "which",
    "with", "would", "write", "your",
}


def read_jsonl(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def anchors(prompt: str) -> tuple[str, str]:
    words = []
    for raw in re.findall(r"[A-Za-z]{5,}", prompt.lower()):
        if raw not in STOP and raw not in words:
            words.append(raw)
    if len(words) < 2:
        words.extend(word for word in ("direct", "specific") if word not in words)
    return words[0], words[1]


def rule(polarity: str, pattern: str) -> dict:
    return {"polarity": polarity, "matcher": "literal", "pattern": pattern}


def rules_for(prompt: str, noise: str) -> list[dict]:
    first, second = anchors(prompt)
    if noise == "clean":
        return [rule("prefer", first), rule("prefer", second),
                rule("prefer", "."), rule("prefer", ","),
                rule("avoid", "\n"), rule("avoid", ":"),
                rule("ban", "private key")]
    if noise == "noisy_20":
        return [rule("prefer", first), rule("prefer", "therefore"),
                rule("prefer", "."), rule("prefer", ";"),
                rule("avoid", "\n"), rule("avoid", ":"),
                rule("ban", "private key")]
    if noise == "noisy_40":
        return [rule("avoid", first), rule("prefer", "therefore"),
                rule("avoid", "."), rule("prefer", ";"),
                rule("prefer", "\n"), rule("avoid", "?"),
                rule("ban", "private key")]
    raise ValueError(noise)


def build(rows: list[dict]) -> list[dict]:
    output = []
    for source in rows:
        ids = [str(value) for value in source.get("instruction_id_list", [])]
        template = "+".join(ids) or "unclassified"
        prompt = str(source["prompt"])
        output.append({
            "key": str(source["key"]),
            "prompt": prompt,
            "instruction_id_list": ids,
            "template": template,
            "rule_sets": {noise: rules_for(prompt, noise)
                          for noise in ("clean", "noisy_20", "noisy_40")},
        })
    return output


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--min-rows", type=int, default=150)
    args = parser.parse_args()
    rows = build(read_jsonl(args.source))
    if len(rows) < args.min_rows:
        raise SystemExit(f"PWSG coverage {len(rows)} is below required {args.min_rows}")
    write_jsonl(args.output, rows)
    write_jsonl(RESULT_OUTPUT, rows)
    print(json.dumps({"rows": len(rows), "output": str(args.output)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
