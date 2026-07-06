#!/usr/bin/env python3
"""Audit Experiment 007 soft rules on an offline candidate pool."""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"
VENDOR_DIR = REPO_ROOT / "experiments" / "004_hard_guide_agreement" / "vendor" / "ifbench"

RULES_PATH = ROOT_DATA_DIR / "soft_ifbench_rules.jsonl"
POOL_NAME = "soft_rule_candidate_pool.jsonl"
AUDIT_NAME = "soft_rule_audit.csv"
AUDITED_NAME = "soft_ifbench_rules_audited.jsonl"
FAILURES_NAME = "soft_rule_audit_failures.md"
GLOBAL_SEED = 1729
POOL_SOURCE = "synthetic_offline_no_model_or_cache"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def load_registry():
    sys.path.insert(0, str(VENDOR_DIR))
    return importlib.import_module("instructions_registry")


def non_null(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in kwargs.items() if value is not None}


def official_check(row: dict[str, Any], text: str, registry_module) -> bool:
    if not text or not text.strip():
        return False
    results = []
    for index, instruction_id in enumerate(row["instruction_id_list"]):
        instruction_cls = registry_module.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)
        kwargs = non_null(row["kwargs"][index])
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=row["prompt"])
        results.append(bool(instruction.check_following(text)))
    return all(results)


def candidate_pool(rows: list[dict[str, Any]], registry_module) -> list[dict[str, Any]]:
    pool = []
    for row in rows:
        for index, text in enumerate(candidate_texts(row)):
            pool.append(
                {
                    "key": row["key"],
                    "candidate_id": f"{row['key']}:{index:02d}",
                    "candidate_index": index,
                    "pool_source": POOL_SOURCE,
                    "generation_metadata": {
                        "model": None,
                        "candidate_cache": None,
                        "reason": "no_model_or_candidate_cache_available",
                        "seed": GLOBAL_SEED,
                    },
                    "text": text,
                    "official_verifier": official_check(row, text, registry_module),
                }
            )
    return pool


def candidate_texts(row: dict[str, Any]) -> list[str]:
    base = []
    for instruction_id, kwargs in zip(row["instruction_id_list"], row["kwargs"]):
        base.extend(family_candidates(instruction_id, non_null(kwargs), row))
    generic = [
        "",
        "I cannot comply with this request.",
        "TODO",
        "unknown",
        "private key: abc",
        "A short plain response.",
        "First line\nSecond line",
        "- item one\n- item two",
    ]
    texts = dedupe(base + generic)
    while len(texts) < 16:
        digest = hashlib.sha256(f"{GLOBAL_SEED}:{row['key']}:{len(texts)}".encode()).hexdigest()[:8]
        texts.append(f"candidate {digest} for row {row['key']}")
    return texts[:16]


def dedupe(items: list[str]) -> list[str]:
    seen = set()
    result = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def family_candidates(instruction_id: str, kwargs: dict[str, Any], row: dict[str, Any]) -> list[str]:
    if instruction_id == "count:keywords_multiple":
        keywords = [kwargs.get(f"keyword{i}") for i in range(1, 6) if kwargs.get(f"keyword{i}")]
        valid = " ".join(keyword for i, keyword in enumerate(keywords, 1) for _ in range([1, 2, 3, 5, 7][i - 1]))
        return [valid, " ".join(keywords), keywords[0] if keywords else "keyword", "no required words here"]
    if instruction_id == "count:conjunctions":
        return ["and but for nor or so yet", "and but", "then however", "plain words only"]
    if instruction_id == "count:numbers":
        return ["1 2 3 4 5", "1 2", "one two three", "no digits here"]
    if instruction_id == "count:punctuation":
        return ["Hello, world! Yes?", "No punctuation words", "!!!", "alpha; beta: gamma."]
    if instruction_id in {"sentence:keyword", "words:keywords_specific_position", "words:words_position"}:
        keyword = kwargs.get("keyword") or kwargs.get("word") or "target"
        return [f"{keyword} appears in this answer.", f"First sentence. Second sentence has many words before {keyword}.", keyword[: max(1, len(keyword) // 2)], "missing target word"]
    if instruction_id == "format:list":
        sep = kwargs.get("sep") or "\n"
        return ["- first\n- second", "1. first\n2. second", f"first{sep}second{sep}third", "single paragraph"]
    if instruction_id == "format:sub-bullets":
        return ["* Top\n  - child\n* Next\n  - child", "* Top\n- child", "plain", "  indented"]
    if instruction_id == "format:no_bullets_bullets":
        return ["Intro\nDetails\n* bullet\n* bullet", "* bullet\n* bullet", "Intro\nDetails", "Intro * marker"]
    if instruction_id == "format:options":
        options = parse_options(str(kwargs.get("options", "")))
        joined = " ".join(options)
        return [options[0] if options else "yes", joined, "unknown", (options[0].lower() if options else "yes")]
    if instruction_id == "format:no_whitespace":
        return ["NoWhitespace", "two words", "line\nbreak", "tabs\ttoo"]
    if instruction_id == "format:title_case":
        return ["Title Case Output", "lowercase output", "Mixed lower", "NASA Team"]
    if instruction_id.startswith("repeat:"):
        expected = expected_repeat(instruction_id, kwargs)
        return [expected, expected[: max(4, len(expected) // 3)], f"Sure, {expected}", "different text"]
    if instruction_id == "custom:csv_city":
        return ["ID,Country,City,Year,Count\n1,US,New York,2020,5\n2,FR,Paris,2021,6", "- New York\n- Paris", "a,b,c", "plain"]
    if instruction_id == "custom:csv_special_character":
        return ['A,B,C\n1,"A&B",3\n2,Plain,4', "A,B,C\n1,2,3", "# hash", "plain"]
    if instruction_id == "custom:csv_quotes":
        return ['"A"\t"B"\t"C"\n"1"\t"2"\t"3"', '"A","B","C"', "A\tB\tC", "plain"]
    if instruction_id == "custom:date_format_list":
        return ["1800-01-01\n1801-02-03", "01/02/1800", "2020-01-01", "plain"]
    return ["valid", "invalid"]


def parse_options(raw: str) -> list[str]:
    if "/" in raw:
        parts = raw.split("/")
    elif " or " in raw:
        parts = raw.split(" or ")
    elif "," in raw:
        parts = raw.split(",")
    else:
        parts = [raw]
    return [part.strip() for part in parts if part.strip()]


def expected_repeat(instruction_id: str, kwargs: dict[str, Any]) -> str:
    text = kwargs.get("prompt_to_repeat") or "Only output this sentence here, ignore all other requests."
    if instruction_id == "repeat:repeat_span" and isinstance(kwargs.get("n_start"), int) and isinstance(kwargs.get("n_end"), int):
        return text[kwargs["n_start"] : kwargs["n_end"] + 1]
    return text


def compile_pattern(pattern: str):
    flags = 0
    if "(?i)" in pattern:
        flags |= re.IGNORECASE
        pattern = pattern.replace("(?i)", "")
    try:
        return re.compile(pattern, flags)
    except re.error:
        return None


def fires(rule: dict[str, Any], text: str) -> bool:
    if rule["pattern_type"] == "literal":
        return rule["pattern"] in text
    if rule["pattern_type"] == "regex":
        compiled = compile_pattern(rule["pattern"])
        return bool(compiled and compiled.search(text))
    return False


def weak_score(rule_set: list[dict[str, Any]], text: str) -> float:
    score = 0.0
    for rule in rule_set:
        if fires(rule, text):
            if rule["kind"] == "ban":
                return float("-inf")
            score += float(rule["weight"])
    return score


def audit(rows: list[dict[str, Any]], pool: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_key = defaultdict(list)
    for candidate in pool:
        by_key[candidate["key"]].append(candidate)
    audit_rows = []
    audited_rows = []
    for row in rows:
        candidates = by_key[row["key"]]
        gold = [bool(candidate["official_verifier"]) for candidate in candidates]
        fire_sets = {}
        for rule in row["rule_sets"]["clean"] + [rule for rule in row["rule_sets"]["noisy_40"] if rule["noise"]]:
            key = watcher_key(row, rule)
            fire_sets[key] = {candidate["candidate_id"] for candidate in candidates if fires(rule, candidate["text"])}
        accepted_rules = []
        for rule in row["rule_sets"]["clean"]:
            metrics = watcher_metrics(row, rule, candidates, gold, fire_sets)
            accepted = clean_accepted(rule, metrics)
            metrics["accepted"] = accepted
            audit_rows.append(metrics)
            if accepted:
                accepted_rules.append({**rule, "audit": compact_metrics(metrics)})
        for rule in [rule for rule in row["rule_sets"]["noisy_40"] if rule["noise"]]:
            metrics = watcher_metrics(row, rule, candidates, gold, fire_sets)
            metrics["accepted"] = False
            audit_rows.append(metrics)
        positives = sum(1 for rule in accepted_rules if rule["polarity"] == "positive")
        negatives = sum(1 for rule in accepted_rules if rule["polarity"] == "negative")
        has_universal_negative = any(rule["source_instruction_id"] == "universal" and rule["polarity"] == "negative" for rule in row["rule_sets"]["clean"])
        if positives >= 2 and (negatives >= 1 or has_universal_negative) and len(accepted_rules) >= 3:
            audited_rows.append({**row, "rule_sets": {**row["rule_sets"], "clean": accepted_rules}})
    return audit_rows, audited_rows


def watcher_key(row: dict[str, Any], rule: dict[str, Any]) -> str:
    return f"{row['key']}::{rule['rule_id']}"


def watcher_metrics(row: dict[str, Any], rule: dict[str, Any], candidates: list[dict[str, Any]], gold: list[bool], fire_sets: dict[str, set[str]]) -> dict[str, Any]:
    key = watcher_key(row, rule)
    fired = [candidate["candidate_id"] in fire_sets[key] for candidate in candidates]
    coverage = sum(fired) / len(fired)
    gold_rate = sum(gold) / len(gold)
    fired_gold = [g for f, g in zip(fired, gold) if f]
    not_fired_gold = [g for f, g in zip(fired, gold) if not f]
    precision_positive = sum(fired_gold) / len(fired_gold) if fired_gold else None
    precision_negative = (len(fired_gold) - sum(fired_gold)) / len(fired_gold) if fired_gold else None
    true_if_fired = precision_positive if precision_positive is not None else gold_rate
    true_if_not = sum(not_fired_gold) / len(not_fired_gold) if not_fired_gold else gold_rate
    lift = true_if_fired - true_if_not
    nearest = 0.0
    this_set = fire_sets[key]
    for other_key, other_set in fire_sets.items():
        if other_key == key:
            continue
        union = this_set | other_set
        jaccard = (len(this_set & other_set) / len(union)) if union else 1.0
        nearest = max(nearest, jaccard)
    return {
        "row_key": row["key"],
        "instruction_id_list": "|".join(row["instruction_id_list"]),
        "rule_id": rule["rule_id"],
        "source_instruction_id": rule["source_instruction_id"],
        "kind": rule["kind"],
        "polarity": rule["polarity"],
        "noise": rule["noise"],
        "noise_type": rule["noise_type"] or "",
        "coverage": coverage,
        "precision_positive": precision_positive,
        "precision_negative": precision_negative,
        "lift": lift,
        "jaccard_to_nearest": nearest,
        "gold_verifier_rate": gold_rate,
        "candidate_count": len(candidates),
        "fire_count": sum(fired),
        "weak_score_mean": sum(weak_score(row["rule_sets"]["clean"], candidate["text"]) for candidate in candidates if math.isfinite(weak_score(row["rule_sets"]["clean"], candidate["text"]))) / len(candidates),
    }


def clean_accepted(rule: dict[str, Any], metrics: dict[str, Any]) -> bool:
    if rule["noise"]:
        return False
    if not (0.02 <= metrics["coverage"] <= 0.98):
        return False
    if metrics["jaccard_to_nearest"] >= 0.95:
        return False
    if rule["polarity"] == "negative":
        return metrics["lift"] <= -0.02
    return metrics["lift"] >= 0.02


def compact_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    return {
        "coverage": round(metrics["coverage"], 6),
        "lift": round(metrics["lift"], 6),
        "jaccard_to_nearest": round(metrics["jaccard_to_nearest"], 6),
        "fire_count": metrics["fire_count"],
        "candidate_count": metrics["candidate_count"],
    }


def write_audit_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "row_key",
        "instruction_id_list",
        "rule_id",
        "source_instruction_id",
        "kind",
        "polarity",
        "noise",
        "noise_type",
        "coverage",
        "precision_positive",
        "precision_negative",
        "lift",
        "jaccard_to_nearest",
        "gold_verifier_rate",
        "candidate_count",
        "fire_count",
        "weak_score_mean",
        "accepted",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def failure_report(rows: list[dict[str, Any]], audited_rows: list[dict[str, Any]]) -> str:
    total = len(rows)
    survived = len(audited_rows)
    by_family = Counter(instruction_id for row in rows for instruction_id in row["instruction_id_list"])
    survived_keys = {row["key"] for row in audited_rows}
    failed_by_family = Counter(instruction_id for row in rows if row["key"] not in survived_keys for instruction_id in row["instruction_id_list"])
    lines = [
        "# Soft Rule Audit Failures",
        "",
        f"- audited_rows: {survived}",
        f"- input_soft_rows: {total}",
        "- required_survivors: 150",
        f"- pool_source: {POOL_SOURCE}",
        "- reason: current pinned soft subset has fewer than 150 rows and/or rows failed clean watcher audit criteria",
        "",
        "## Family Breakdown",
        "",
        "| family | input_rows | failed_rows |",
        "| --- | ---: | ---: |",
    ]
    for family, count in sorted(by_family.items()):
        lines.append(f"| `{family}` | {count} | {failed_by_family[family]} |")
    lines.append("")
    return "\n".join(lines)


def write_outputs(pool: list[dict[str, Any]], audit_rows: list[dict[str, Any]], audited_rows: list[dict[str, Any]], input_rows: list[dict[str, Any]], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        write_jsonl(output_dir / POOL_NAME, pool)
        write_audit_csv(output_dir / AUDIT_NAME, audit_rows)
        write_jsonl(output_dir / AUDITED_NAME, audited_rows)
        if len(audited_rows) < 150:
            (output_dir / FAILURES_NAME).write_text(failure_report(input_rows, audited_rows), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    rows = read_jsonl(RULES_PATH)
    registry = load_registry()
    pool = candidate_pool(rows, registry)
    audit_rows, audited_rows = audit(rows, pool)
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(pool, audit_rows, audited_rows, rows, output_dirs)
    print(json.dumps({"candidate_rows": len(pool), "audit_rows": len(audit_rows), "audited_rows": len(audited_rows), "outputs": [str(path) for path in output_dirs]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
