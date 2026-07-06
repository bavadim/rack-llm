#!/usr/bin/env python3
"""Audit Experiment 012 soft rules on the real Qwen candidate pool."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import regex

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
AUDIT_CODE_DIR = REPO_ROOT / "experiments" / "008_soft_rule_audit" / "code"

RULES_PATH = ROOT_DATA_DIR / "soft_ifbench_rules.jsonl"
POOL_PATH = ROOT_DATA_DIR / "012_soft_candidate_pool.jsonl"
AUDIT_NAME = "012_soft_rule_audit.csv"
AUDITED_NAME = "012_soft_ifbench_rules_audited.jsonl"
FAILURES_NAME = "012_soft_rule_audit_failures.md"
MIN_AUDITED_ROWS = 150
REGEX_TIMEOUT_SECONDS = 0.01

sys.path.insert(0, str(AUDIT_CODE_DIR))
from run_soft_rule_audit import clean_accepted, compact_metrics, write_audit_csv, write_jsonl  # noqa: E402


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def audit(rows: list[dict[str, Any]], pool: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_key: dict[str, list[dict[str, Any]]] = {}
    for candidate in pool:
        by_key.setdefault(candidate["key"], []).append(candidate)
    audit_rows = []
    audited_rows = []
    for row in rows:
        candidates = by_key.get(row["key"], [])
        if not candidates:
            continue
        clean_rules = decorrelate_clean_rules(row, candidates, row["rule_sets"]["clean"])
        noisy_rules = decorrelate_noisy_rules(row, candidates, clean_rules, [rule for rule in row["rule_sets"]["noisy_40"] if rule["noise"]])
        rules = clean_rules + noisy_rules
        fire_masks = {watcher_key(row, rule): fire_mask(rule, candidates) for rule in rules}
        gold_mask = 0
        for index, candidate in enumerate(candidates):
            if candidate.get("official_verifier"):
                gold_mask |= 1 << index
        accepted_rules = []
        weak_scores = weak_scores_for(clean_rules, candidates, row, fire_masks)
        for rule in clean_rules:
            metrics = watcher_metrics(row, rule, candidates, gold_mask, fire_masks, weak_scores)
            accepted = clean_accepted(rule, metrics)
            metrics["accepted"] = accepted
            audit_rows.append(metrics)
            if accepted:
                accepted_rules.append({**rule, "audit": compact_metrics(metrics)})
        for rule in noisy_rules:
            metrics = watcher_metrics(row, rule, candidates, gold_mask, fire_masks, weak_scores)
            metrics["accepted"] = False
            audit_rows.append(metrics)
        positives = sum(1 for rule in accepted_rules if rule["polarity"] == "positive")
        negatives = sum(1 for rule in accepted_rules if rule["polarity"] == "negative")
        has_universal_negative = any(
            rule["source_instruction_id"] == "universal" and rule["polarity"] == "negative"
            for rule in row["rule_sets"]["clean"]
        )
        auditable_rule_count = len(accepted_rules) + (1 if has_universal_negative and negatives == 0 else 0)
        if positives >= 2 and (negatives >= 1 or has_universal_negative) and auditable_rule_count >= 3:
            audited_rows.append({**row, "rule_sets": {**row["rule_sets"], "clean": accepted_rules}})
    return audit_rows, audited_rows


def decorrelate_clean_rules(row: dict[str, Any], candidates: list[dict[str, Any]], rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    masks = [fire_mask(rule, candidates) for rule in rules]
    keep: list[int] = []
    kept_masks: list[int] = []
    for index in sorted(range(len(rules)), key=lambda i: rule_priority(rules[i]), reverse=True):
        mask = masks[index]
        if all(jaccard(mask, kept_mask) < 0.95 for kept_mask in kept_masks):
            keep.append(index)
            kept_masks.append(mask)
    return [rules[index] for index in sorted(keep)]


def decorrelate_noisy_rules(
    row: dict[str, Any],
    candidates: list[dict[str, Any]],
    clean_rules: list[dict[str, Any]],
    noisy_rules: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    clean_masks = [fire_mask(rule, candidates) for rule in clean_rules]
    output = []
    for rule in noisy_rules:
        mask = fire_mask(rule, candidates)
        if all(jaccard(mask, clean_mask) < 0.95 for clean_mask in clean_masks):
            output.append(rule)
    return output


def jaccard(left: int, right: int) -> float:
    union = left | right
    return ((left & right).bit_count() / union.bit_count()) if union else 1.0


def rule_priority(rule: dict[str, Any]) -> float:
    rule_id = rule["rule_id"]
    source = rule["source_instruction_id"]
    score = 0.0
    if rule["kind"] == "ban":
        score += 100.0
    if source != "universal":
        score += 40.0
    if not source.startswith("surface:"):
        score += 20.0
    if any(marker in rule_id for marker in ("exact", "literal", "repeated", "nested", "same_initial")):
        score += 15.0
    if any(marker in rule_id for marker in ("hint", "generic", "wordy_response")):
        score -= 10.0
    if rule_id.startswith("universal_"):
        score -= 20.0
    score += min(len(str(rule.get("pattern", ""))) / 50.0, 10.0)
    return score


def watcher_key(row: dict[str, Any], rule: dict[str, Any]) -> str:
    return f"{row['key']}::{rule['rule_id']}"


def fire_mask(rule: dict[str, Any], candidates: list[dict[str, Any]]) -> int:
    mask = 0
    for index, candidate in enumerate(candidates):
        if fires(rule, candidate.get("text", "")):
            mask |= 1 << index
    return mask


def fires(rule: dict[str, Any], text: str) -> bool:
    pattern = rule["pattern"]
    try:
        if rule["pattern_type"] == "literal":
            return pattern in text
        if rule["pattern_type"] == "regex":
            compiled = regex.compile(pattern, regex.MULTILINE | regex.DOTALL)
            return compiled.search(text, timeout=REGEX_TIMEOUT_SECONDS) is not None
    except (regex.error, TimeoutError):
        return False
    return False


def weak_scores_for(clean_rules: list[dict[str, Any]], candidates: list[dict[str, Any]], row: dict[str, Any], fire_masks: dict[str, int]) -> list[float]:
    scores = []
    for index, _candidate in enumerate(candidates):
        bit = 1 << index
        score = 0.0
        banned = False
        for rule in clean_rules:
            if fire_masks[watcher_key(row, rule)] & bit:
                if rule["kind"] == "ban":
                    banned = True
                    break
                score += float(rule["weight"])
        scores.append(float("-inf") if banned else score)
    return scores


def watcher_metrics(
    row: dict[str, Any],
    rule: dict[str, Any],
    candidates: list[dict[str, Any]],
    gold_mask: int,
    fire_masks: dict[str, int],
    weak_scores: list[float],
) -> dict[str, Any]:
    key = watcher_key(row, rule)
    mask = fire_masks[key]
    all_mask = (1 << len(candidates)) - 1
    fired_count = mask.bit_count()
    coverage = fired_count / len(candidates)
    gold_count = gold_mask.bit_count()
    gold_rate = gold_count / len(candidates)
    fired_gold_count = (mask & gold_mask).bit_count()
    not_mask = all_mask ^ mask
    not_fired_count = len(candidates) - fired_count
    not_fired_gold_count = (not_mask & gold_mask).bit_count()
    precision_positive = fired_gold_count / fired_count if fired_count else None
    precision_negative = (fired_count - fired_gold_count) / fired_count if fired_count else None
    true_if_fired = precision_positive if precision_positive is not None else gold_rate
    true_if_not = not_fired_gold_count / not_fired_count if not_fired_count else gold_rate
    nearest = 0.0
    for other_key, other_mask in fire_masks.items():
        if other_key == key:
            continue
        union = mask | other_mask
        jaccard = ((mask & other_mask).bit_count() / union.bit_count()) if union else 1.0
        nearest = max(nearest, jaccard)
    finite_scores = [score for score in weak_scores if math.isfinite(score)]
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
        "lift": true_if_fired - true_if_not,
        "jaccard_to_nearest": nearest,
        "gold_verifier_rate": gold_rate,
        "candidate_count": len(candidates),
        "fire_count": fired_count,
        "weak_score_mean": sum(finite_scores) / len(candidates) if finite_scores else 0.0,
    }


def failure_report(rows: list[dict[str, Any]], audited_rows: list[dict[str, Any]], pool: list[dict[str, Any]]) -> str:
    survived_keys = {row["key"] for row in audited_rows}
    by_family = Counter(instruction_id.split(":", 1)[0] for row in rows for instruction_id in row["instruction_id_list"])
    failed_by_family = Counter(
        instruction_id.split(":", 1)[0]
        for row in rows
        if row["key"] not in survived_keys
        for instruction_id in row["instruction_id_list"]
    )
    pool_sources = Counter(candidate["pool_source"] for candidate in pool)
    lines = [
        "# Soft Rule Audit Failures",
        "",
        f"- audited_rows: {len(audited_rows)}",
        f"- input_soft_rows: {len(rows)}",
        f"- required_survivors: {MIN_AUDITED_ROWS}",
        f"- candidate_rows: {len(pool)}",
        f"- pool_sources: {dict(pool_sources)}",
        "- reason: rows failed clean watcher audit criteria on real Qwen candidates",
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


def write_outputs(audit_rows: list[dict[str, Any]], audited_rows: list[dict[str, Any]], input_rows: list[dict[str, Any]], pool: list[dict[str, Any]]) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    write_audit_csv(RESULTS_DIR / AUDIT_NAME, audit_rows)
    write_jsonl(RESULTS_DIR / AUDITED_NAME, audited_rows)
    failure_text = failure_report(input_rows, audited_rows, pool)
    (RESULTS_DIR / FAILURES_NAME).write_text(failure_text, encoding="utf-8")
    shutil.copyfile(RESULTS_DIR / AUDIT_NAME, ROOT_DATA_DIR / AUDIT_NAME)
    shutil.copyfile(RESULTS_DIR / AUDITED_NAME, ROOT_DATA_DIR / AUDITED_NAME)
    shutil.copyfile(RESULTS_DIR / FAILURES_NAME, ROOT_DATA_DIR / FAILURES_NAME)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args(argv)
    rows = read_jsonl(RULES_PATH)
    pool = read_jsonl(POOL_PATH)
    audit_rows, audited_rows = audit(rows, pool)
    write_outputs(audit_rows, audited_rows, rows, pool)
    print(json.dumps({"audit_rows": len(audit_rows), "audited_rows": len(audited_rows), "candidate_rows": len(pool)}, sort_keys=True))
    return 0 if len(audited_rows) >= MIN_AUDITED_ROWS else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
