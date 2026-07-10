#!/usr/bin/env python3
"""Calibrate Experiment 012 soft-rule scores and compute rule correlations."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

try:
    import regex as regex_module
except ModuleNotFoundError:
    regex_module = re

from strict_json import strict_json_dumps


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"

RULES_PATH = ROOT_DATA_DIR / "012_soft_ifbench_rules_audited.jsonl"
POOL_PATH = ROOT_DATA_DIR / "012_soft_candidate_pool.jsonl"

ROOT_FEATURES = ROOT_DATA_DIR / "012_soft_rule_feature_table.jsonl"
ROOT_CALIBRATION = ROOT_DATA_DIR / "012_soft_rule_calibration.csv"
ROOT_CORRELATIONS = ROOT_DATA_DIR / "012_soft_rule_correlations.csv"
ROOT_CALIBRATED = ROOT_DATA_DIR / "012_soft_ifbench_rules_calibrated.jsonl"

RESULTS_FEATURES = RESULTS_DIR / "012_soft_rule_feature_table.jsonl"
RESULTS_CALIBRATION = RESULTS_DIR / "012_soft_rule_calibration.csv"
RESULTS_CORRELATIONS = RESULTS_DIR / "012_soft_rule_correlations.csv"
RESULTS_CALIBRATED = RESULTS_DIR / "012_soft_ifbench_rules_calibrated.jsonl"
REPORT_OUTPUT = RESULTS_DIR / "027_soft_rule_calibration_report.json"

NOISE_LEVELS = ("clean", "noisy_20", "noisy_40")
REGEX_TIMEOUT_SECONDS = 0.01
ALPHA = 1.0
SHRINK_K = 20.0
CLIP_LOW = -4.0
CLIP_HIGH = 4.0
MIN_FIRE_FOR_RULE_ID = 5
MIN_FIRE_FOR_GROUP = 5
REGEX_CACHE: dict[str, Any] = {}

CALIBRATION_FIELDS = [
    "key",
    "split_scope",
    "noise",
    "rule_id",
    "source_instruction_id",
    "kind",
    "polarity",
    "noise_type",
    "pattern_type",
    "n_candidates",
    "fire_count",
    "coverage",
    "p_ok_if_fired",
    "p_ok_if_not_fired",
    "lift",
    "raw_weight",
    "calibrated_weight",
    "calibration_key",
    "calibration_status",
]

CORRELATION_FIELDS = [
    "key",
    "noise",
    "left_rule_id",
    "right_rule_id",
    "n11",
    "n10",
    "n01",
    "n00",
    "jaccard",
    "phi",
    "duplicate_candidate",
]


class Stat:
    def __init__(self) -> None:
        self.n = 0
        self.fire = 0
        self.ok = 0
        self.ok_fire = 0

    def update(self, fired: bool, ok: bool) -> None:
        self.n += 1
        self.ok += int(ok)
        if fired:
            self.fire += 1
            self.ok_fire += int(ok)

    @property
    def bad_fire(self) -> int:
        return self.fire - self.ok_fire

    @property
    def not_fire(self) -> int:
        return self.n - self.fire

    @property
    def ok_not_fire(self) -> int:
        return self.ok - self.ok_fire

    @property
    def bad_not_fire(self) -> int:
        return self.not_fire - self.ok_not_fire


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(strict_json_dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def split_for_key(key: str) -> str:
    digest = int(hashlib.sha256(key.encode("utf-8")).hexdigest()[:8], 16)
    return "dev" if digest % 10 < 3 else "test"


def group_key(rule: dict[str, Any]) -> str:
    return "|".join(
        [
            str(rule.get("source_instruction_id", "")),
            str(rule.get("kind", "")),
            str(rule.get("polarity", "")),
            str(rule.get("noise_type") or ""),
            str(rule.get("pattern_type", "")),
        ]
    )


def fires(rule: dict[str, Any], text: str) -> bool:
    pattern = str(rule.get("pattern", ""))
    try:
        if rule.get("pattern_type") == "literal":
            return pattern in text
        if rule.get("pattern_type") == "regex":
            compiled = REGEX_CACHE.get(pattern)
            if compiled is None:
                compiled = regex_module.compile(pattern, regex_module.MULTILINE | regex_module.DOTALL)
                REGEX_CACHE[pattern] = compiled
            if regex_module is re:
                return compiled.search(text) is not None
            return compiled.search(text, timeout=REGEX_TIMEOUT_SECONDS) is not None
    except (regex_module.error, TimeoutError):
        return False
    return False


def mask_for(rule: dict[str, Any], candidates: list[dict[str, Any]]) -> int:
    mask = 0
    for index, candidate in enumerate(candidates):
        if fires(rule, str(candidate.get("text", ""))):
            mask |= 1 << index
    return mask


def finite_weight(rule: dict[str, Any]) -> float:
    value = float(rule.get("weight", 0.0))
    if not math.isfinite(value):
        return 0.0
    return value


def calibrated_from_stat(stat: Stat) -> float:
    log_odds = math.log((stat.ok_fire + ALPHA) / (stat.bad_fire + ALPHA)) - math.log(
        (stat.ok_not_fire + ALPHA) / (stat.bad_not_fire + ALPHA)
    )
    shrunk = log_odds * stat.fire / (stat.fire + SHRINK_K)
    return min(CLIP_HIGH, max(CLIP_LOW, shrunk))


def metrics_from_stat(stat: Stat) -> dict[str, Any]:
    p_ok_if_fired = (stat.ok_fire / stat.fire) if stat.fire else ""
    p_ok_if_not_fired = (stat.ok_not_fire / stat.not_fire) if stat.not_fire else ""
    if p_ok_if_fired == "" or p_ok_if_not_fired == "":
        lift = ""
    else:
        lift = p_ok_if_fired - p_ok_if_not_fired
    return {
        "n_candidates": stat.n,
        "fire_count": stat.fire,
        "coverage": (stat.fire / stat.n) if stat.n else "",
        "p_ok_if_fired": p_ok_if_fired,
        "p_ok_if_not_fired": p_ok_if_not_fired,
        "lift": lift,
    }


def auroc(pairs: list[tuple[float, bool]]) -> float | str:
    finite = [(score, label) for score, label in pairs if math.isfinite(score)]
    positives = [score for score, label in finite if label]
    negatives = [score for score, label in finite if not label]
    if not positives or not negatives:
        return ""
    wins = 0.0
    for pos in positives:
        for neg in negatives:
            wins += 1.0 if pos > neg else 0.5 if pos == neg else 0.0
    return wins / (len(positives) * len(negatives))


def auprc(pairs: list[tuple[float, bool]]) -> float | str:
    finite = sorted([(score, label) for score, label in pairs if math.isfinite(score)], reverse=True)
    total_pos = sum(1 for _score, label in finite if label)
    if total_pos == 0:
        return ""
    tp = 0
    precisions = []
    for rank, (_score, label) in enumerate(finite, start=1):
        if label:
            tp += 1
            precisions.append(tp / rank)
    return sum(precisions) / total_pos


def risk_coverage_summary(pairs: list[tuple[float, bool]], risk_target: float = 0.05) -> dict[str, Any]:
    finite = sorted([(score, label) for score, label in pairs if math.isfinite(score)], reverse=True)
    if not finite:
        return {"coverage_at_risk": 0.0, "found_ok_at_risk": 0.0, "threshold_score": ""}
    best = {"coverage_at_risk": 0.0, "found_ok_at_risk": 0.0, "threshold_score": ""}
    total = len(finite)
    ok = 0
    wrong = 0
    for index, (score, label) in enumerate(finite, start=1):
        ok += int(label)
        wrong += int(not label)
        risk = wrong / index
        if risk <= risk_target:
            best = {
                "coverage_at_risk": index / total,
                "found_ok_at_risk": ok / total,
                "threshold_score": score,
            }
    return best


def phi(n11: int, n10: int, n01: int, n00: int) -> float | str:
    denom = (n11 + n10) * (n01 + n00) * (n11 + n01) * (n10 + n00)
    if denom == 0:
        return ""
    return ((n11 * n00) - (n10 * n01)) / math.sqrt(denom)


def correlation_row(key: str, noise: str, left_id: str, right_id: str, left_mask: int, right_mask: int, n: int) -> dict[str, Any]:
    n11 = (left_mask & right_mask).bit_count()
    n10 = (left_mask & ~right_mask).bit_count()
    n01 = (right_mask & ~left_mask).bit_count()
    n00 = n - n11 - n10 - n01
    denom = n11 + n10 + n01
    jaccard = (n11 / denom) if denom else 1.0
    return {
        "key": key,
        "noise": noise,
        "left_rule_id": left_id,
        "right_rule_id": right_id,
        "n11": n11,
        "n10": n10,
        "n01": n01,
        "n00": n00,
        "jaccard": jaccard,
        "phi": phi(n11, n10, n01, n00),
        "duplicate_candidate": jaccard >= 0.95,
    }


def build() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    rows = read_jsonl(RULES_PATH)
    pool = read_jsonl(POOL_PATH)
    keys = {row["key"] for row in rows}
    pool_by_key: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for candidate in pool:
        if candidate["key"] in keys:
            pool_by_key[candidate["key"]].append(candidate)

    rule_id_stats: dict[tuple[str, str], Stat] = defaultdict(Stat)
    group_stats: dict[tuple[str, str], Stat] = defaultdict(Stat)
    masks: dict[tuple[str, str, str, int], int] = {}
    rule_occurrences: list[tuple[dict[str, Any], str, dict[str, Any], int]] = []

    for row in rows:
        candidates = pool_by_key[row["key"]]
        split = split_for_key(row["key"])
        for noise in NOISE_LEVELS:
            for rule_index, rule in enumerate(row["rule_sets"][noise]):
                mask = mask_for(rule, candidates)
                masks[(row["key"], noise, rule["rule_id"], rule_index)] = mask
                rule_occurrences.append((row, noise, rule, rule_index))
                if split != "dev":
                    continue
                rid_stat = rule_id_stats[(noise, rule["rule_id"])]
                group_stat = group_stats[(noise, group_key(rule))]
                for candidate_index, candidate in enumerate(candidates):
                    fired = bool(mask & (1 << candidate_index))
                    ok = bool(candidate["official_verifier"])
                    rid_stat.update(fired, ok)
                    group_stat.update(fired, ok)

    calibration_by_occurrence: dict[tuple[str, str, str, int], dict[str, Any]] = {}
    calibration_rows: list[dict[str, Any]] = []
    fallback_counts: dict[str, Counter[str]] = {noise: Counter() for noise in NOISE_LEVELS}

    for row, noise, rule, rule_index in rule_occurrences:
        occurrence = (row["key"], noise, rule["rule_id"], rule_index)
        raw_weight = rule.get("weight", "")
        if rule["kind"] == "ban":
            calibration = {
                "calibrated_weight": raw_weight,
                "calibration_key": f"hard_ban:{rule['rule_id']}",
                "calibration_status": "hard_ban",
            }
            chosen_stat = rule_id_stats.get((noise, rule["rule_id"]), Stat())
        else:
            rid_key = (noise, rule["rule_id"])
            grp_key = (noise, group_key(rule))
            rid_stat = rule_id_stats.get(rid_key)
            grp_stat = group_stats.get(grp_key)
            if rid_stat and rid_stat.fire >= MIN_FIRE_FOR_RULE_ID:
                chosen_stat = rid_stat
                calibration = {
                    "calibrated_weight": calibrated_from_stat(rid_stat),
                    "calibration_key": f"rule_id:{rule['rule_id']}",
                    "calibration_status": "ok",
                }
            elif grp_stat and grp_stat.fire >= MIN_FIRE_FOR_GROUP:
                chosen_stat = grp_stat
                calibration = {
                    "calibrated_weight": calibrated_from_stat(grp_stat),
                    "calibration_key": f"group:{group_key(rule)}",
                    "calibration_status": "fallback_group",
                }
            else:
                chosen_stat = rid_stat or grp_stat or Stat()
                calibration = {
                    "calibrated_weight": finite_weight(rule),
                    "calibration_key": "original_weight",
                    "calibration_status": "fallback_original",
                }
        fallback_counts[noise][calibration["calibration_status"]] += 1
        calibration_by_occurrence[occurrence] = calibration
        stat_metrics = metrics_from_stat(chosen_stat)
        calibration_rows.append(
            {
                "key": row["key"],
                "split_scope": "dev_training",
                "noise": noise,
                "rule_id": rule["rule_id"],
                "source_instruction_id": rule.get("source_instruction_id", ""),
                "kind": rule["kind"],
                "polarity": rule.get("polarity", ""),
                "noise_type": rule.get("noise_type") or "",
                "pattern_type": rule.get("pattern_type", ""),
                **stat_metrics,
                "raw_weight": raw_weight,
                "calibrated_weight": "" if rule["kind"] == "ban" else calibration["calibrated_weight"],
                "calibration_key": calibration["calibration_key"],
                "calibration_status": calibration["calibration_status"],
            }
        )

    calibrated_rows: list[dict[str, Any]] = []
    for row in rows:
        calibrated_rule_sets = {}
        for noise in NOISE_LEVELS:
            calibrated_rules = []
            for rule_index, rule in enumerate(row["rule_sets"][noise]):
                calibration = calibration_by_occurrence[(row["key"], noise, rule["rule_id"], rule_index)]
                updated = dict(rule)
                updated["raw_weight"] = rule.get("weight")
                updated.update(calibration)
                if rule["kind"] == "rank":
                    updated["weight"] = calibration["calibrated_weight"]
                calibrated_rules.append(updated)
            calibrated_rule_sets[noise] = calibrated_rules
        calibrated_rows.append({**row, "calibrated_rule_sets": calibrated_rule_sets})

    feature_rows: list[dict[str, Any]] = []
    score_pairs: dict[tuple[str, str, str], list[tuple[float, bool]]] = defaultdict(list)
    for row in rows:
        candidates = pool_by_key[row["key"]]
        split = split_for_key(row["key"])
        for noise in NOISE_LEVELS:
            rules = row["rule_sets"][noise]
            for candidate_index, candidate in enumerate(candidates):
                bit = 1 << candidate_index
                fired_ids = []
                raw_score = 0.0
                calibrated_score = 0.0
                banned = False
                for rule_index, rule in enumerate(rules):
                    if not (masks[(row["key"], noise, rule["rule_id"], rule_index)] & bit):
                        continue
                    fired_ids.append(rule["rule_id"])
                    if rule["kind"] == "ban":
                        banned = True
                        break
                    raw_score += finite_weight(rule)
                    calibrated_score += float(
                        calibration_by_occurrence[(row["key"], noise, rule["rule_id"], rule_index)]["calibrated_weight"]
                    )
                if banned:
                    raw_value = float("-inf")
                    calibrated_value = float("-inf")
                else:
                    raw_value = raw_score
                    calibrated_value = calibrated_score
                label = bool(candidate["official_verifier"])
                score_pairs[(noise, split, "raw")].append((raw_value, label))
                score_pairs[(noise, split, "calibrated")].append((calibrated_value, label))
                feature_rows.append(
                    {
                        "key": row["key"],
                        "split": split,
                        "noise": noise,
                        "candidate_id": candidate["candidate_id"],
                        "official_verifier": label,
                        "fired_rule_ids": fired_ids,
                        "raw_score": raw_value,
                        "calibrated_score": calibrated_value,
                        "banned": banned,
                    }
                )

    correlation_rows: list[dict[str, Any]] = []
    for row in rows:
        candidates = pool_by_key[row["key"]]
        for noise in NOISE_LEVELS:
            rules = row["rule_sets"][noise]
            for left_index in range(len(rules)):
                for right_index in range(left_index + 1, len(rules)):
                    left = rules[left_index]
                    right = rules[right_index]
                    correlation_rows.append(
                        correlation_row(
                            row["key"],
                            noise,
                            left["rule_id"],
                            right["rule_id"],
                            masks[(row["key"], noise, left["rule_id"], left_index)],
                            masks[(row["key"], noise, right["rule_id"], right_index)],
                            len(candidates),
                        )
                    )

    report = {
        "input_rows": len(rows),
        "candidate_rows": sum(len(pool_by_key[row["key"]]) for row in rows),
        "feature_rows": len(feature_rows),
        "calibration_rows": len(calibration_rows),
        "correlation_rows": len(correlation_rows),
        "defaults": {
            "alpha": ALPHA,
            "shrink_k": SHRINK_K,
            "clip": [CLIP_LOW, CLIP_HIGH],
            "min_fire_for_rule_id": MIN_FIRE_FOR_RULE_ID,
            "min_fire_for_group": MIN_FIRE_FOR_GROUP,
        },
        "uses_test_labels_for_training": False,
        "noise": {},
    }
    for noise in NOISE_LEVELS:
        noise_feature_rows = [row for row in feature_rows if row["noise"] == noise]
        noise_corr_rows = [row for row in correlation_rows if row["noise"] == noise]
        report["noise"][noise] = {
            "rows": len(rows),
            "candidates": len(noise_feature_rows),
            "rules": sum(len(row["rule_sets"][noise]) for row in rows),
            "dev_label_rate": label_rate(noise_feature_rows, "dev"),
            "test_label_rate": label_rate(noise_feature_rows, "test"),
            "raw": metric_report(score_pairs[(noise, "dev", "raw")], score_pairs[(noise, "test", "raw")]),
            "calibrated": metric_report(
                score_pairs[(noise, "dev", "calibrated")],
                score_pairs[(noise, "test", "calibrated")],
            ),
            "fallback_rules": dict(fallback_counts[noise]),
            "high_correlation_duplicate_pairs": sum(1 for row in noise_corr_rows if row["duplicate_candidate"]),
        }
    return feature_rows, calibration_rows, correlation_rows, calibrated_rows, report


def label_rate(rows: list[dict[str, Any]], split: str) -> float | str:
    selected = [row for row in rows if row["split"] == split]
    if not selected:
        return ""
    return sum(1 for row in selected if row["official_verifier"]) / len(selected)


def metric_report(dev_pairs: list[tuple[float, bool]], test_pairs: list[tuple[float, bool]]) -> dict[str, Any]:
    return {
        "dev": {
            "AUROC": auroc(dev_pairs),
            "AUPRC": auprc(dev_pairs),
            "risk_coverage": risk_coverage_summary(dev_pairs),
        },
        "test": {
            "AUROC": auroc(test_pairs),
            "AUPRC": auprc(test_pairs),
            "risk_coverage": risk_coverage_summary(test_pairs),
        },
    }


def write_outputs(
    feature_rows: list[dict[str, Any]],
    calibration_rows: list[dict[str, Any]],
    correlation_rows: list[dict[str, Any]],
    calibrated_rows: list[dict[str, Any]],
    report: dict[str, Any],
    experiment_only: bool,
) -> None:
    write_jsonl(RESULTS_FEATURES, feature_rows)
    write_csv(RESULTS_CALIBRATION, calibration_rows, CALIBRATION_FIELDS)
    write_csv(RESULTS_CORRELATIONS, correlation_rows, CORRELATION_FIELDS)
    write_jsonl(RESULTS_CALIBRATED, calibrated_rows)
    REPORT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    REPORT_OUTPUT.write_text(strict_json_dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if not experiment_only:
        write_jsonl(ROOT_FEATURES, feature_rows)
        write_csv(ROOT_CALIBRATION, calibration_rows, CALIBRATION_FIELDS)
        write_csv(ROOT_CORRELATIONS, correlation_rows, CORRELATION_FIELDS)
        write_jsonl(ROOT_CALIBRATED, calibrated_rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    outputs = build()
    write_outputs(*outputs, experiment_only=args.experiment_only)
    report = outputs[-1]
    print(json.dumps({k: report[k] for k in ["input_rows", "feature_rows", "calibration_rows", "correlation_rows"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
