from __future__ import annotations

import json
import math
import os
import re
import subprocess
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

import numpy as np

from .common import (
    ARTIFACT_ROOT, CACHE, file_hash, load_config, read_jsonl, stable_hash,
    stable_json,
)
from .evaluator import load_evaluator, official_check_many
from .metrics import corrected_bootstrap_p, effective_rank


PROTOCOL = "post-failure-official-v1"
SOURCE_RUN_RE = re.compile(r"^[0-9a-f]{16}$")
EXPECTED_INSTANCES = 480
EXPECTED_CANDIDATES = 11_040
PRIMARY_TEMPERATURE = 1.0
AUDIT_TEMPERATURE = 0.7
PRIMARY_SEEDS = set(range(20))
PAIRED_SEEDS = set(range(8))
THRESHOLDS = {
    "minimum_class_candidates": 50,
    "minimum_class_prompts": 10,
    "minimum_rule_fires": 24,
    "minimum_rule_coverage": 0.04,
    "maximum_rule_coverage": 0.90,
    "minimum_firing_prompts": 6,
    "maximum_prompt_fire_share": 0.25,
    "maximum_rule_jaccard": 0.95,
    "minimum_conflict_rate": 0.01,
    "minimum_desired_precision": 0.65,
    "minimum_desired_lift": 0.10,
    "minimum_technical_rules": 5,
    "minimum_positive_rules": 2,
    "minimum_negative_rules": 1,
    "minimum_gold_aligned_rules": 3,
    "output_corruption_rate": 0.05,
    "cap_association_rate": 0.10,
    "cap_invalidity_lift": 0.15,
    "temperature_effect": 0.10,
}
EVALUATOR_FILES = (
    "evaluation_lib.py", "instructions.py", "instructions_registry.py",
    "instructions_util.py",
)
OUTPUT_NAMES = {
    "candidate_labels.jsonl", "family_summary.jsonl", "prompt_summary.jsonl",
    "temperature_pairs.jsonl", "rule_summary.jsonl", "root_causes.jsonl",
    "summary.json", "REPORT.md",
}


def _atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False,
    ) + "\n"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _atomic_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        for row in rows:
            handle.write(stable_json(row) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _tree_hashes(root: Path) -> dict[str, str]:
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError(f"diagnostic source is not a real directory: {root}")
    output = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"diagnostic source contains a symlink: {path}")
        if path.is_file():
            output[str(path.relative_to(root))] = file_hash(path)
    return output


def _required_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"missing regular diagnostic input: {relative}")
    return path


def _validate_evaluator(manifest: dict[str, Any]) -> dict[str, str]:
    root = CACHE / "ifbench"
    expected_revision = manifest.get("ifbench_revision")
    actual_revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True,
    ).strip()
    if not expected_revision or actual_revision != expected_revision:
        raise RuntimeError("pinned IFBench revision differs from failed source run")
    external = manifest.get("external_files", {})
    expected_by_relative = {}
    for raw_path, expected in external.items():
        path = Path(raw_path).resolve()
        try:
            relative = str(path.relative_to(root.resolve()))
        except ValueError:
            continue
        expected_by_relative[relative] = expected
    actual_paths = [root / name for name in EVALUATOR_FILES]
    nltk = root / ".nltk_data"
    if nltk.is_dir():
        actual_paths.extend(path for path in nltk.rglob("*") if path.is_file())
    actual_by_relative = {
        str(path.resolve().relative_to(root.resolve())): path for path in actual_paths
    }
    if set(actual_by_relative) != set(expected_by_relative):
        raise RuntimeError("pinned evaluator dependency inventory drift")
    hashes = {}
    for relative, path in sorted(actual_by_relative.items()):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError(f"pinned evaluator dependency is not a regular file: {relative}")
        actual = file_hash(path)
        if expected_by_relative[relative] != actual:
            raise RuntimeError(f"pinned evaluator dependency drift: {relative}")
        hashes[relative] = actual
    return hashes


def _finite(value: float) -> float | None:
    return float(value) if math.isfinite(value) else None


def _bootstrap_p(values: np.ndarray) -> float | None:
    finite = values[np.isfinite(values)]
    return corrected_bootstrap_p(finite) if len(finite) else None


def _candidate_id(row: dict[str, Any]) -> str:
    return stable_hash({
        "prompt_id": row["prompt_id"],
        "model_family": row["model_family"],
        "temperature": row["temperature"],
        "seed": row["seed"],
        "sample_index": row["sample_index"],
        "text": row["text"],
        "token_ids": row["token_ids"],
    })


def _labels_for_slots(
    observation: dict[str, Any], rules_by_slot: dict[int, dict[str, Any]],
    slots: list[int],
) -> list[int]:
    labels_by_rule = dict(zip(
        observation["rule_ids"], observation["labels"], strict=True,
    ))
    return [int(labels_by_rule[rules_by_slot[slot]["rule_id"]]) for slot in slots]


def _expected_grid(instances: list[dict[str, Any]]) -> set[tuple[str, float, int, int]]:
    expected = set()
    for row in instances:
        if row["split"] == "calibration":
            protocols = ((PRIMARY_TEMPERATURE, PRIMARY_SEEDS),
                         (AUDIT_TEMPERATURE, PAIRED_SEEDS))
        elif row["split"] == "dev":
            protocols = ((PRIMARY_TEMPERATURE, PAIRED_SEEDS),)
        else:
            raise RuntimeError(f"forbidden diagnostic split: {row['split']}")
        for temperature, seeds in protocols:
            for seed in seeds:
                expected.add((str(row["id"]), temperature, seed, 0))
    return expected


def validate_source(source_run_id: str) -> dict[str, Any]:
    if not SOURCE_RUN_RE.fullmatch(source_run_id):
        raise RuntimeError("source run id must contain exactly 16 lowercase hex digits")
    unresolved_source = ARTIFACT_ROOT / source_run_id
    if unresolved_source.is_symlink():
        raise RuntimeError("source run directory must not be a symlink")
    source = unresolved_source.resolve()
    if source.parent != ARTIFACT_ROOT.resolve():
        raise RuntimeError("source run escapes the artifact root")
    if source != unresolved_source.absolute():
        raise RuntimeError("source run path contains a symlink")
    before = _tree_hashes(source)
    manifest_path = _required_file(source, "frozen_manifest.json")
    state_path = _required_file(source, "RUN_STATE.json")
    instances_path = _required_file(source, "inputs/main_design_candidate_instances.jsonl")
    candidates_path = _required_file(source, "raw/main_design_candidate_pool.jsonl")
    observations_path = _required_file(
        source, "observations/main_design_noise_00_candidate.jsonl",
    )
    filter_path = _required_file(
        source, "reports/main_design_noise_00_filter.json",
    )
    observation_meta_path = _required_file(
        source, "observations/main_design_noise_00_candidate.jsonl.meta.json",
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if manifest.get("run_id") != source_run_id or state.get("run_id") != source_run_id:
        raise RuntimeError("source directory, manifest, and state run ids differ")
    if state.get("state") != "FAILED" or state.get("failed") != ["design"]:
        raise RuntimeError("post-failure diagnostic requires FAILED design state")
    evaluator_hashes = _validate_evaluator(manifest)
    instances = read_jsonl(instances_path)
    candidates = read_jsonl(candidates_path)
    observations = read_jsonl(observations_path)
    filter_report = json.loads(filter_path.read_text(encoding="utf-8"))
    if len(instances) != EXPECTED_INSTANCES:
        raise RuntimeError(f"expected {EXPECTED_INSTANCES} instances, got {len(instances)}")
    if len(candidates) != EXPECTED_CANDIDATES or len(observations) != EXPECTED_CANDIDATES:
        raise RuntimeError("candidate/observation cardinality differs from frozen v4 design")
    instance_ids = [str(row.get("id", "")) for row in instances]
    if len(instance_ids) != len(set(instance_ids)) or "" in instance_ids:
        raise RuntimeError("duplicate or empty instance id")
    instance_by_id = dict(zip(instance_ids, instances, strict=True))
    if {row.get("split") for row in instances} != {"calibration", "dev"}:
        raise RuntimeError("diagnostic instances must contain calibration/dev only")
    if Counter(row["split"] for row in instances) != {"calibration": 360, "dev": 120}:
        raise RuntimeError("unexpected calibration/dev instance counts")
    family_instances = Counter((row["split"], row["family"]) for row in instances)
    if (
        len({family for split, family in family_instances if split == "calibration"}) != 12
        or len({family for split, family in family_instances if split == "dev"}) != 12
        or any(count != (30 if split == "calibration" else 10)
               for (split, _family), count in family_instances.items())
    ):
        raise RuntimeError("unexpected per-family calibration/dev instance counts")

    candidate_ids = [str(row.get("candidate_id", "")) for row in candidates]
    observation_ids = [str(row.get("candidate_id", "")) for row in observations]
    if len(candidate_ids) != len(set(candidate_ids)) or "" in candidate_ids:
        raise RuntimeError("duplicate or empty candidate id")
    if len(observation_ids) != len(set(observation_ids)) or set(observation_ids) != set(candidate_ids):
        raise RuntimeError("candidate and observation ids do not form the same unique set")
    expected = _expected_grid(instances)
    actual = set()
    for row in candidates:
        prompt_id = str(row.get("prompt_id", ""))
        instance = instance_by_id.get(prompt_id)
        if instance is None:
            raise RuntimeError(f"candidate references unknown prompt: {prompt_id}")
        if row.get("split") not in {"calibration", "dev"}:
            raise RuntimeError(f"forbidden candidate split: {row.get('split')}")
        if row.get("family") != instance["family"] or row.get("split") != instance["split"]:
            raise RuntimeError(f"candidate metadata differs from prompt: {row['candidate_id']}")
        if row.get("status") != "found" or row.get("hard_valid") is not True:
            raise RuntimeError(f"invalid candidate return: {row['candidate_id']}")
        if _candidate_id(row) != row["candidate_id"]:
            raise RuntimeError(f"candidate id hash mismatch: {row['candidate_id']}")
        key = (prompt_id, round(float(row["temperature"]), 12),
               int(row["seed"]), int(row["sample_index"]))
        if key in actual:
            raise RuntimeError(f"duplicate candidate cohort key: {key}")
        actual.add(key)
    if actual != expected:
        raise RuntimeError(
            f"incomplete diagnostic candidate grid: missing={len(expected-actual)}, "
            f"extra={len(actual-expected)}"
        )
    observation_by_id = {row["candidate_id"]: row for row in observations}
    candidate_by_id = {row["candidate_id"]: row for row in candidates}
    for candidate_id, row in observation_by_id.items():
        candidate = candidate_by_id[candidate_id]
        if row.get("record_type") != "observation":
            raise RuntimeError(f"non-observation row: {candidate_id}")
        for key in ("prompt_id", "family", "split", "seed", "sample_index"):
            if row.get(key) != candidate.get(key):
                raise RuntimeError(f"observation metadata mismatch: {candidate_id}/{key}")
        if abs(float(row["temperature"]) - float(candidate["temperature"])) > 1e-12:
            raise RuntimeError(f"observation temperature mismatch: {candidate_id}")
        if len(row.get("rule_ids", [])) != len(row.get("labels", [])):
            raise RuntimeError(f"observation width mismatch: {candidate_id}")
        expected_rule_ids = {
            rule["rule_id"] for rule in instance_by_id[row["prompt_id"]]["weak_rules"]
        }
        actual_rule_ids = list(row.get("rule_ids", []))
        if len(actual_rule_ids) != len(set(actual_rule_ids)) or set(actual_rule_ids) != expected_rule_ids:
            raise RuntimeError(f"observation rule ids mismatch: {candidate_id}")
    observation_meta = json.loads(observation_meta_path.read_text(encoding="utf-8"))
    if (
        observation_meta.get("rows") != EXPECTED_CANDIDATES
        or observation_meta.get("run_id") != source_run_id
        or observation_meta.get("output_sha256") != file_hash(observations_path)
    ):
        raise RuntimeError("observation metadata does not authenticate the frozen rows")
    selected_slots = {
        family: list(map(int, slots))
        for family, slots in filter_report.get("selected_slots", {}).items()
    }
    calibration_example = {
        row["family"]: row for row in instances if row["split"] == "calibration"
    }
    primary_observations: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in observations:
        if row["split"] == "calibration" and abs(float(row["temperature"]) - 1.0) < 1e-12:
            primary_observations[row["family"]].append(row)
    source_gate_failures = set()
    for family, example in calibration_example.items():
        slots = selected_slots.get(family, [])
        rules_by_slot = {int(rule["slot"]): rule for rule in example["weak_rules"]}
        if any(slot not in rules_by_slot for slot in slots):
            raise RuntimeError(f"selected rule slot is absent from builder output: {family}")
        polarities = [rules_by_slot[slot]["polarity"] for slot in slots]
        matrix = np.asarray([
            _labels_for_slots(row, rules_by_slot, slots)
            for row in primary_observations[family]
        ], dtype=int) if slots else np.empty((0, 0), dtype=int)
        conflict = bool(len(matrix) and np.logical_and(
            (matrix > 0).any(axis=1), (matrix < 0).any(axis=1),
        ).any())
        if (
            len(slots) < 5 or polarities.count("positive") < 2
            or polarities.count("negative") < 1 or not conflict
        ):
            source_gate_failures.add(family)
    state_failures = set(re.findall(r"'family': '([^']+)'", str(state.get("reason", ""))))
    if state_failures and state_failures != source_gate_failures:
        raise RuntimeError("source state failure list differs from frozen filter/observations")
    return {
        "source_run_id": source_run_id,
        "source": source,
        "manifest": manifest,
        "source_hashes": before,
        "evaluator_hashes": evaluator_hashes,
        "instances_path": instances_path,
        "candidates_path": candidates_path,
        "observations_path": observations_path,
        "filter_path": filter_path,
        "instances": instances,
        "candidates": candidates,
        "observations": observations,
        "source_gate_failures": sorted(source_gate_failures),
    }


def _seed(base: int, *parts: Any) -> int:
    return int(stable_hash([base, *parts])[:8], 16)


def _interval(values: np.ndarray, confidence: float) -> tuple[float | None, float | None, int]:
    finite = values[np.isfinite(values)]
    if not len(finite):
        return None, None, 0
    tail = (1.0 - confidence) / 2.0
    return (
        float(np.quantile(finite, tail)),
        float(np.quantile(finite, 1.0 - tail)),
        int(len(finite)),
    )


def _bootstrap_prompt_values(
    values: dict[str, float], *, repetitions: int, confidence: float, seed: int,
) -> dict[str, Any]:
    ordered = np.asarray([values[key] for key in sorted(values)], dtype=float)
    if not len(ordered):
        return {"point": None, "ci_low": None, "ci_high": None, "support": 0}
    rng = np.random.default_rng(seed)
    indices = rng.integers(0, len(ordered), size=(repetitions, len(ordered)))
    samples = ordered[indices].mean(axis=1)
    low, high, support = _interval(samples, confidence)
    return {
        "point": float(ordered.mean()), "ci_low": low, "ci_high": high,
        "support": support,
    }


def _bootstrap_count_statistic(
    values: dict[str, np.ndarray], statistic: Callable[[np.ndarray], float],
    *, repetitions: int, confidence: float, seed: int,
) -> tuple[float | None, float | None, int, np.ndarray]:
    matrix = np.stack([values[key] for key in sorted(values)])
    rng = np.random.default_rng(seed)
    indices = rng.integers(0, len(matrix), size=(repetitions, len(matrix)))
    samples = np.asarray([statistic(matrix[index].sum(axis=0)) for index in indices])
    low, high, support = _interval(samples, confidence)
    return low, high, support, samples


_REFUSAL = re.compile(r"\b(?:I (?:cannot|can't|won't)|unable to (?:help|comply))\b", re.I)
_REASONING = re.compile(r"</?(?:think|thinking|analysis)>", re.I)
_CHAT = re.compile(r"<\|(?:im_start|im_end|user|assistant)\|>", re.I)


def _health(row: dict[str, Any], instance: dict[str, Any]) -> dict[str, bool]:
    text = str(row.get("text", ""))
    values = {
        "at_cap": int(row.get("token_count", 0)) >= int(instance["max_tokens"]),
        "refusal": bool(_REFUSAL.search(text)),
        "reasoning_leak": bool(_REASONING.search(text)),
        "chat_leak": bool(_CHAT.search(text)),
        "prompt_echo": str(instance["prompt"]) in text,
        "very_short": int(row.get("token_count", 0)) < 10,
        "replacement_character": "\ufffd" in text,
        "unexpected_script": bool(re.search(r"[\u3400-\u9fff\u0400-\u04ff\u0600-\u06ff]", text)),
    }
    values["corrupt"] = any(values[key] for key in (
        "refusal", "reasoning_leak", "chat_leak", "prompt_echo",
        "very_short", "replacement_character",
    ))
    return values


def _family_tables(
    enriched: list[dict[str, Any]], *, repetitions: int, confidence: float, seed: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    groups: dict[tuple[str, str, float], list[dict[str, Any]]] = defaultdict(list)
    for row in enriched:
        groups[(row["family"], row["split"], row["temperature"])].append(row)
    family_rows = []
    prompt_rows = []
    for (family, split, temperature), rows in sorted(groups.items()):
        by_prompt: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for row in rows:
            by_prompt[row["prompt_id"]].append(row)
        prompt_rates = {}
        cap_counts = {}
        for prompt, values in sorted(by_prompt.items()):
            valid = sum(row["gold_pass"] for row in values)
            capped = sum(row["health"]["at_cap"] for row in values)
            corrupt = sum(row["health"]["corrupt"] for row in values)
            prompt_rates[prompt] = valid / len(values)
            cap_invalid = sum(
                row["health"]["at_cap"] and not row["gold_pass"] for row in values
            )
            complete_invalid = sum(
                not row["health"]["at_cap"] and not row["gold_pass"] for row in values
            )
            cap_counts[prompt] = np.asarray([
                cap_invalid, capped, complete_invalid, len(values) - capped,
            ], dtype=float)
            prompt_rows.append({
                "family": family, "split": split, "temperature": temperature,
                "prompt_id": prompt, "candidates": len(values),
                "gold_valid": valid, "gold_invalid": len(values) - valid,
                "valid_rate": valid / len(values), "at_cap_rate": capped / len(values),
                "corruption_rate": corrupt / len(values),
            })
        validity = _bootstrap_prompt_values(
            prompt_rates, repetitions=repetitions, confidence=confidence,
            seed=_seed(seed, "validity", family, split, temperature),
        )

        def cap_lift(counts: np.ndarray) -> float:
            cap_invalid, cap_total, complete_invalid, complete_total = counts
            if cap_total <= 0 or complete_total <= 0:
                return float("nan")
            return float(cap_invalid / cap_total - complete_invalid / complete_total)

        cap_low, cap_high, cap_support, _ = _bootstrap_count_statistic(
            cap_counts, cap_lift, repetitions=repetitions, confidence=confidence,
            seed=_seed(seed, "cap", family, split, temperature),
        )
        totals = np.stack(list(cap_counts.values())).sum(axis=0)
        valid = sum(row["gold_pass"] for row in rows)
        health_keys = list(rows[0]["health"])
        family_rows.append({
            "family": family, "split": split, "temperature": temperature,
            "candidates": len(rows), "prompts": len(by_prompt),
            "gold_valid": valid, "gold_invalid": len(rows) - valid,
            "valid_prompts": sum(any(row["gold_pass"] for row in values)
                                 for values in by_prompt.values()),
            "invalid_prompts": sum(any(not row["gold_pass"] for row in values)
                                   for values in by_prompt.values()),
            "prompt_macro_valid_rate": validity["point"],
            "valid_rate_ci_low": validity["ci_low"],
            "valid_rate_ci_high": validity["ci_high"],
            "bootstrap_support": validity["support"],
            **{
                f"{key}_rate": sum(row["health"][key] for row in rows) / len(rows)
                for key in health_keys
            },
            "at_cap_candidates": int(totals[1]),
            "complete_candidates": int(totals[3]),
            "invalid_at_cap": int(totals[0]),
            "invalid_when_complete": int(totals[2]),
            "invalidity_lift_at_cap": _finite(cap_lift(totals)),
            "invalidity_lift_at_cap_ci_low": cap_low,
            "invalidity_lift_at_cap_ci_high": cap_high,
            "cap_bootstrap_support": cap_support,
        })
    return family_rows, prompt_rows


def _paired_temperature(
    enriched: list[dict[str, Any]], *, repetitions: int, confidence: float, seed: int,
) -> list[dict[str, Any]]:
    rows = [row for row in enriched if row["split"] == "calibration"
            and int(row["seed"]) in PAIRED_SEEDS]
    groups: dict[str, dict[tuple[str, int], dict[float, bool]]] = defaultdict(
        lambda: defaultdict(dict)
    )
    for row in rows:
        groups[row["family"]][(row["prompt_id"], int(row["seed"]))][
            round(float(row["temperature"]), 12)
        ] = bool(row["gold_pass"])
    output = []
    for family, pairs in sorted(groups.items()):
        expected = {AUDIT_TEMPERATURE, PRIMARY_TEMPERATURE}
        if any(set(values) != expected for values in pairs.values()):
            raise RuntimeError(f"incomplete paired temperature grid: {family}")
        by_prompt: dict[str, list[float]] = defaultdict(list)
        for (prompt, candidate_seed), values in pairs.items():
            by_prompt[prompt].append(
                float(values[PRIMARY_TEMPERATURE]) - float(values[AUDIT_TEMPERATURE])
            )
        if any(len(values) != len(PAIRED_SEEDS) for values in by_prompt.values()):
            raise RuntimeError(f"invalid paired seed cohort: {family}")
        prompt_delta = {prompt: float(np.mean(values)) for prompt, values in by_prompt.items()}
        ordered = np.asarray([prompt_delta[key] for key in sorted(prompt_delta)])
        rng = np.random.default_rng(_seed(seed, "temperature", family))
        indices = rng.integers(0, len(ordered), size=(repetitions, len(ordered)))
        samples = ordered[indices].mean(axis=1)
        low, high, support = _interval(samples, confidence)
        output.append({
            "family": family, "temperature_a": AUDIT_TEMPERATURE,
            "temperature_b": PRIMARY_TEMPERATURE,
            "delta_b_minus_a": float(ordered.mean()), "ci_low": low,
            "ci_high": high, "bootstrap_support": support,
            "bootstrap_p": _bootstrap_p(samples),
            "prompts": len(ordered), "paired_seeds": len(PAIRED_SEEDS),
        })
    _holm(output)
    return output


def _holm(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        row["holm_p"] = None
    ordered = sorted(
        [row for row in rows if row["bootstrap_p"] is not None],
        key=lambda row: float(row["bootstrap_p"]),
    )
    running = 0.0
    total = len(ordered)
    for index, row in enumerate(ordered):
        running = max(running, min(1.0, (total - index) * float(row["bootstrap_p"])))
        row["holm_p"] = running


def _rule_tables(
    enriched: list[dict[str, Any]], instances: list[dict[str, Any]],
    *, repetitions: int, confidence: float, seed: int,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    scoped = [row for row in enriched if row["split"] == "calibration"
              and abs(row["temperature"] - PRIMARY_TEMPERATURE) < 1e-12]
    instance_by_id = {row["id"]: row for row in instances}
    rules: dict[tuple[str, str], dict[str, Any]] = {}
    fires: dict[tuple[str, str], set[str]] = defaultdict(set)
    contributions: dict[tuple[str, str], dict[str, np.ndarray]] = defaultdict(
        lambda: defaultdict(lambda: np.zeros(4, dtype=float))
    )
    family_vectors: dict[str, list[list[int]]] = defaultdict(list)
    family_candidate_ids: dict[str, list[str]] = defaultdict(list)
    for row in scoped:
        ordered_rules = sorted(
            instance_by_id[row["prompt_id"]]["weak_rules"],
            key=lambda rule: int(rule["slot"]),
        )
        observation = row["observation"]
        vector_by_rule = dict(zip(observation["rule_ids"], observation["labels"], strict=True))
        family_vector = []
        for rule in ordered_rules:
            rule_id = rule["rule_id"]
            key = (row["family"], rule_id)
            metadata = rules.setdefault(key, {
                "family": row["family"], "rule_id": rule_id,
                "slot": int(rule["slot"]),
                "author": "A" if int(rule["source_slot"]) < 5 else "B",
                "polarity": rule["polarity"],
            })
            if metadata["slot"] != int(rule["slot"]) or metadata["polarity"] != rule["polarity"]:
                raise RuntimeError(f"inconsistent rule metadata: {key}")
            label = int(vector_by_rule.get(rule_id, 0))
            expected_sign = 1 if rule["polarity"] == "positive" else -1
            if label not in (0, expected_sign):
                raise RuntimeError(f"rule emitted wrong polarity: {key}/{label}")
            fired = label != 0
            desired = bool(row["gold_pass"]) if expected_sign > 0 else not bool(row["gold_pass"])
            bucket = contributions[key][row["prompt_id"]]
            bucket[0 if fired and desired else 1 if fired else 2 if desired else 3] += 1
            if fired:
                fires[key].add(row["candidate_id"])
            family_vector.append(label)
        family_vectors[row["family"]].append(family_vector)
        family_candidate_ids[row["family"]].append(row["candidate_id"])
    output = []
    for key, metadata in sorted(rules.items(), key=lambda item: (item[0][0], item[1]["slot"])):
        prompt_counts = contributions[key]
        totals = np.stack(list(prompt_counts.values())).sum(axis=0)
        fire_desired, fire_undesired, abstain_desired, abstain_undesired = totals
        fire_total = fire_desired + fire_undesired
        desired_total = fire_desired + abstain_desired
        abstain_total = abstain_desired + abstain_undesired

        def lift(counts: np.ndarray) -> float:
            fd, fu, ad, au = counts
            if fd + fu <= 0 or ad + au <= 0:
                return float("nan")
            return float(fd / (fd + fu) - ad / (ad + au))

        low, high, support, samples = _bootstrap_count_statistic(
            prompt_counts, lift, repetitions=repetitions, confidence=confidence,
            seed=_seed(seed, "rule", *key),
        )
        firing_by_prompt = {
            prompt: int(values[0] + values[1]) for prompt, values in prompt_counts.items()
        }
        row = {
            **metadata, "candidates": int(totals.sum()), "fires": int(fire_total),
            "abstains": int(abstain_total),
            "firing_prompts": sum(value > 0 for value in firing_by_prompt.values()),
            "max_prompt_fire_share": (
                max(firing_by_prompt.values()) / fire_total if fire_total else None
            ),
            "fire_desired": int(fire_desired), "fire_undesired": int(fire_undesired),
            "abstain_desired": int(abstain_desired),
            "abstain_undesired": int(abstain_undesired),
            "coverage": float(fire_total / totals.sum()),
            "desired_precision": float(fire_desired / fire_total) if fire_total else None,
            "desired_recall": float(fire_desired / desired_total) if desired_total else None,
            "desired_lift": _finite(lift(totals)), "desired_lift_ci_low": low,
            "desired_lift_ci_high": high, "bootstrap_support": support,
            "bootstrap_p": _bootstrap_p(samples),
            "odds_ratio_haldane": float(
                ((fire_desired + .5) * (abstain_undesired + .5))
                / ((fire_undesired + .5) * (abstain_desired + .5))
            ),
        }
        output.append(row)
    for family in sorted({row["family"] for row in output}):
        _holm([row for row in output if row["family"] == family])
        candidates = family_candidate_ids[family]
        by_id = {candidate: index for index, candidate in enumerate(candidates)}
        eligible = []
        for row in [value for value in output if value["family"] == family]:
            reasons = []
            if not THRESHOLDS["minimum_rule_coverage"] <= row["coverage"] <= THRESHOLDS["maximum_rule_coverage"]:
                reasons.append("coverage")
            if row["fires"] < THRESHOLDS["minimum_rule_fires"]:
                reasons.append("fires")
            if row["firing_prompts"] < THRESHOLDS["minimum_firing_prompts"]:
                reasons.append("firing_prompts")
            if row["max_prompt_fire_share"] is None or row["max_prompt_fire_share"] > THRESHOLDS["maximum_prompt_fire_share"]:
                reasons.append("prompt_concentration")
            row["failure_reasons"] = reasons
            if not reasons:
                eligible.append(row)
        selected = []
        for row in sorted(eligible, key=lambda value: value["slot"]):
            duplicate = None
            row_set = fires[(family, row["rule_id"])]
            maximum = 0.0
            for prior in selected:
                prior_set = fires[(family, prior["rule_id"])]
                union = len(row_set | prior_set)
                jaccard = len(row_set & prior_set) / union if union else 1.0
                maximum = max(maximum, jaccard)
                if jaccard >= THRESHOLDS["maximum_rule_jaccard"] and duplicate is None:
                    duplicate = prior["slot"]
            row["max_jaccard_to_selected"] = maximum
            row["duplicate_of_slot"] = duplicate
            if duplicate is None:
                selected.append(row)
            else:
                row["failure_reasons"].append("jaccard_duplicate")
        for row in [value for value in output if value["family"] == family]:
            row.setdefault("max_jaccard_to_selected", None)
            row.setdefault("duplicate_of_slot", None)
            row["technical_usable"] = not row["failure_reasons"]
            row["gold_aligned"] = bool(
                row["technical_usable"]
                and row["desired_precision"] is not None
                and row["desired_precision"] >= THRESHOLDS["minimum_desired_precision"]
                and row["desired_lift"] is not None
                and row["desired_lift"] >= THRESHOLDS["minimum_desired_lift"]
                and row["desired_lift_ci_low"] is not None
                and row["desired_lift_ci_low"] > 0
                and row["holm_p"] is not None
                and row["holm_p"] <= 1.0 - confidence + 1e-12
            )
    family_inventory = {}
    for family in sorted({row["family"] for row in output}):
        selected = [row for row in output if row["family"] == family and row["technical_usable"]]
        id_to_column = {
            rule["rule_id"]: index for index, rule in enumerate(
                sorted([row for row in output if row["family"] == family], key=lambda value: value["slot"])
            )
        }
        selected_columns = [id_to_column[row["rule_id"]] for row in selected]
        matrix = np.asarray(family_vectors[family], dtype=float)
        selected_matrix = matrix[:, selected_columns] if selected_columns else np.empty((len(matrix), 0))
        conflict = float(np.mean(
            (selected_matrix > 0).any(axis=1) & (selected_matrix < 0).any(axis=1)
        )) if selected_columns else 0.0
        aligned = [row for row in selected if row["gold_aligned"]]
        family_inventory[family] = {
            "technical_rules": len(selected),
            "positive_rules": sum(row["polarity"] == "positive" for row in selected),
            "negative_rules": sum(row["polarity"] == "negative" for row in selected),
            "conflict_rate": conflict,
            "effective_rank": effective_rank(selected_matrix),
            "gold_aligned_rules": len(aligned),
            "gold_aligned_authors": sorted({row["author"] for row in aligned}),
        }
    return output, family_inventory


def _root_causes(
    primary: dict[str, dict[str, Any]], inventory: dict[str, dict[str, Any]],
    temperatures: dict[str, dict[str, Any]], source_gate_failures: set[str],
) -> list[dict[str, Any]]:
    output = []
    for family in sorted(primary):
        row = primary[family]
        rules = inventory[family]
        temperature = temperatures[family]
        class_support = bool(
            row["gold_valid"] >= THRESHOLDS["minimum_class_candidates"]
            and row["gold_invalid"] >= THRESHOLDS["minimum_class_candidates"]
            and row["valid_prompts"] >= THRESHOLDS["minimum_class_prompts"]
            and row["invalid_prompts"] >= THRESHOLDS["minimum_class_prompts"]
        )
        inventory_sound = bool(
            rules["technical_rules"] >= THRESHOLDS["minimum_technical_rules"]
            and rules["positive_rules"] >= THRESHOLDS["minimum_positive_rules"]
            and rules["negative_rules"] >= THRESHOLDS["minimum_negative_rules"]
            and rules["conflict_rate"] >= THRESHOLDS["minimum_conflict_rate"]
        )
        semantic_sound = bool(
            rules["gold_aligned_rules"] >= THRESHOLDS["minimum_gold_aligned_rules"]
            and len(rules["gold_aligned_authors"]) >= 2
        )
        semantic_evaluable = bool(
            rules["technical_rules"] >= THRESHOLDS["minimum_technical_rules"]
            and rules["positive_rules"] >= THRESHOLDS["minimum_positive_rules"]
            and rules["negative_rules"] >= THRESHOLDS["minimum_negative_rules"]
        )
        signals = []
        if not class_support:
            signals.extend(["CLASS_IMBALANCE", "PROMPT_OR_MODEL_FOR_CLASS_BALANCE"])
        if class_support and not inventory_sound:
            signals.append("RULE_INVENTORY")
        if class_support and semantic_evaluable and not semantic_sound:
            signals.append("RULE_SEMANTICS")
        elif class_support and not semantic_evaluable:
            signals.append("RULE_SEMANTICS_NOT_ESTABLISHED")
        if row["corrupt_rate"] > THRESHOLDS["output_corruption_rate"]:
            signals.append("OUTPUT_CORRUPTION")
        cap_candidate = bool(
            row["at_cap_rate"] >= THRESHOLDS["cap_association_rate"]
            and row["invalidity_lift_at_cap"] is not None
            and row["invalidity_lift_at_cap"] >= THRESHOLDS["cap_invalidity_lift"]
            and row["invalidity_lift_at_cap_ci_low"] is not None
            and row["invalidity_lift_at_cap_ci_low"] > 0
        )
        if cap_candidate:
            signals.append("TOKEN_BUDGET_VALIDITY_ASSOCIATION")
        temperature_effect = bool(
            abs(temperature["delta_b_minus_a"]) >= THRESHOLDS["temperature_effect"]
            and temperature["ci_low"] is not None and temperature["ci_high"] is not None
            and (temperature["ci_low"] > 0 or temperature["ci_high"] < 0)
            and temperature.get("holm_p") is not None
            and temperature["holm_p"] <= 0.05
        )
        if temperature_effect:
            signals.append("TEMPERATURE")
        if not signals:
            signals.append("NO_POSTHOC_SIGNAL")
        source_gate_failed = family in source_gate_failures
        blocking_causes = ["RULE_INVENTORY"] if source_gate_failed else []
        output.append({
            "family": family, "source_gate_failed": source_gate_failed,
            "blocking_causes": blocking_causes, "posthoc_signals": signals,
            "class_support": class_support, "rule_inventory_sound": inventory_sound,
            "rule_semantics_evaluable": semantic_evaluable,
            "rule_semantics_sound": semantic_sound if semantic_evaluable else None,
            "matched_budget_rerun_required_for_validity": cap_candidate,
            "pilot_required_for_class_balance": not class_support,
            "base_answer_completeness_assessed": False,
            "evidence": {
                "gold_valid": row["gold_valid"], "gold_invalid": row["gold_invalid"],
                "valid_prompts": row["valid_prompts"],
                "invalid_prompts": row["invalid_prompts"],
                "technical_rules": rules["technical_rules"],
                "positive_rules": rules["positive_rules"],
                "negative_rules": rules["negative_rules"],
                "conflict_rate": rules["conflict_rate"],
                "gold_aligned_rules": rules["gold_aligned_rules"],
                "at_cap_rate": row["at_cap_rate"],
                "at_cap_candidates": row["at_cap_candidates"],
                "complete_candidates": row["complete_candidates"],
                "invalidity_lift_at_cap": row["invalidity_lift_at_cap"],
                "corruption_rate": row["corrupt_rate"],
                "temperature_delta": temperature["delta_b_minus_a"],
                "temperature_holm_p": temperature.get("holm_p"),
            },
        })
    return output


def analyze(
    instances: list[dict[str, Any]], candidates: list[dict[str, Any]],
    observations: list[dict[str, Any]], labels: list[dict[str, Any]],
    *, diagnostic_parameters: dict[str, Any] | None = None,
    source_gate_failures: set[str] | None = None,
) -> dict[str, Any]:
    if diagnostic_parameters is None:
        config = load_config()
        diagnostic_parameters = {
            "bootstrap_repetitions": int(config["bootstrap_repetitions"]),
            "confidence": float(config["confidence"]),
            "dataset_seed": int(config["dataset_seed"]),
        }
    repetitions = int(diagnostic_parameters["bootstrap_repetitions"])
    confidence = float(diagnostic_parameters["confidence"])
    seed = int(diagnostic_parameters["dataset_seed"])
    instance_by_id = {row["id"]: row for row in instances}
    observation_by_id = {row["candidate_id"]: row for row in observations}
    label_ids = [row.get("candidate_id") for row in labels]
    if len(labels) != len(candidates) or len(label_ids) != len(set(label_ids)):
        raise RuntimeError("official labels are incomplete or duplicated")
    gold = {row["candidate_id"]: bool(row["gold_pass"]) for row in labels}
    candidate_ids = {row["candidate_id"] for row in candidates}
    if set(gold) != candidate_ids:
        raise RuntimeError("official labels do not match the candidate pool")
    enriched = []
    for row in candidates:
        observation = observation_by_id[row["candidate_id"]]
        instance = instance_by_id[row["prompt_id"]]
        enriched.append({
            **row, "temperature": round(float(row["temperature"]), 12),
            "gold_pass": gold[row["candidate_id"]], "observation": observation,
            "health": _health(row, instance),
        })
    family_rows, prompt_rows = _family_tables(
        enriched, repetitions=repetitions, confidence=confidence, seed=seed,
    )
    temperatures = _paired_temperature(
        enriched, repetitions=repetitions, confidence=confidence, seed=seed,
    )
    rule_rows, inventory = _rule_tables(
        enriched, instances, repetitions=repetitions, confidence=confidence, seed=seed,
    )
    primary = {
        row["family"]: row for row in family_rows
        if row["split"] == "calibration"
        and abs(row["temperature"] - PRIMARY_TEMPERATURE) < 1e-12
    }
    temperature_by_family = {row["family"]: row for row in temperatures}
    causes = _root_causes(
        primary, inventory, temperature_by_family, source_gate_failures or set(),
    )
    return {
        "family_rows": family_rows, "prompt_rows": prompt_rows,
        "temperature_rows": temperatures, "rule_rows": rule_rows,
        "inventory": inventory, "root_causes": causes,
        "bootstrap": {
            "repetitions": repetitions, "confidence": confidence, "seed": seed,
            "unit": "prompt", "seeds_retained_within_prompt": True,
        },
    }


def _report_markdown(analysis: dict[str, Any]) -> str:
    primary = {
        row["family"]: row for row in analysis["family_rows"]
        if row["split"] == "calibration" and row["temperature"] == PRIMARY_TEMPERATURE
    }
    roots = {row["family"]: row for row in analysis["root_causes"]}
    lines = [
        "# Retrospective failed-design diagnostic", "",
        "> Posthoc and non-confirmatory. No test or test_official row was read.", "",
        "| Family | Valid | Invalid | Valid rate | Cap | Technical rules | Source blocker | Posthoc signals |",
        "|---|---:|---:|---:|---:|---:|---|---|",
    ]
    for family in sorted(primary):
        row = primary[family]
        inventory = analysis["inventory"][family]
        blockers = ", ".join(roots[family]["blocking_causes"]) or "—"
        signals = ", ".join(roots[family]["posthoc_signals"])
        lines.append(
            f"| {family} | {row['gold_valid']} | {row['gold_invalid']} | "
            f"{row['prompt_macro_valid_rate']:.3f} | {row['at_cap_rate']:.3f} | "
            f"{inventory['technical_rules']} | {blockers} | {signals} |"
        )
    return "\n".join(lines) + "\n"


def _verify_complete(
    destination: Path, *, identity: dict[str, Any], diagnostic_id: str,
) -> Path:
    if destination.is_symlink() or destination.resolve() != destination.absolute():
        raise RuntimeError("diagnostic destination path contains a symlink")
    state_path = _required_file(destination, "DIAGNOSTIC_STATE.json")
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if state.get("state") != "COMPLETE":
        raise RuntimeError(f"diagnostic destination already exists in {state.get('state')} state")
    manifest = json.loads(_required_file(destination, "manifest.json").read_text(encoding="utf-8"))
    if destination.name != diagnostic_id or diagnostic_id != "diag-" + stable_hash(identity)[:16]:
        raise RuntimeError("diagnostic directory is not content-addressed by expected identity")
    if state.get("diagnostic_id") != diagnostic_id or manifest.get("diagnostic_id") != diagnostic_id:
        raise RuntimeError("completed diagnostic id mismatch")
    for key, expected in identity.items():
        if manifest.get(key) != expected:
            raise RuntimeError(f"completed diagnostic identity drift: {key}")
    if set(manifest.get("output_hashes", {})) != OUTPUT_NAMES:
        raise RuntimeError("completed diagnostic output inventory drift")
    if state.get("manifest_sha256") != file_hash(destination / "manifest.json"):
        raise RuntimeError("completed diagnostic manifest drift")
    for relative, expected in manifest["output_hashes"].items():
        if file_hash(_required_file(destination, relative)) != expected:
            raise RuntimeError(f"completed diagnostic output drift: {relative}")
    return destination


def run_postmortem(source_run_id: str) -> Path:
    source = validate_source(source_run_id)
    config = load_config()
    diagnostic_parameters = {
        "bootstrap_repetitions": int(config["bootstrap_repetitions"]),
        "confidence": float(config["confidence"]),
        "dataset_seed": int(config["dataset_seed"]),
        "evaluator_workers": max(1, int(config["runtime"]["evaluator_workers"])),
    }
    module_root = Path(__file__).resolve().parent
    code_hashes = {
        name: file_hash(module_root / name)
        for name in ("postmortem.py", "common.py", "evaluator.py", "metrics.py")
    }
    identity = {
        "protocol": PROTOCOL, "source_run_id": source_run_id,
        "source_tree_sha256": stable_hash(source["source_hashes"]),
        "source_manifest_sha256": source["source_hashes"]["frozen_manifest.json"],
        "source_state_sha256": source["source_hashes"]["RUN_STATE.json"],
        "instances_sha256": file_hash(source["instances_path"]),
        "candidates_sha256": file_hash(source["candidates_path"]),
        "observations_sha256": file_hash(source["observations_path"]),
        "filter_sha256": file_hash(source["filter_path"]),
        "evaluator_hashes": source["evaluator_hashes"],
        "diagnostic_code_hashes": code_hashes,
        "diagnostic_parameters": diagnostic_parameters,
    }
    diagnostic_id = "diag-" + stable_hash(identity)[:16]
    destination = ARTIFACT_ROOT / diagnostic_id
    if destination.is_symlink():
        raise RuntimeError("diagnostic destination must not be a symlink")
    try:
        destination.mkdir(parents=False, exist_ok=False)
    except FileExistsError:
        return _verify_complete(
            destination, identity=identity, diagnostic_id=diagnostic_id,
        )
    _atomic_json(destination / "DIAGNOSTIC_STATE.json", {
        "diagnostic_id": diagnostic_id, "source_run_id": source_run_id,
        "state": "RUNNING", "retrospective_after_design_failure": True,
    })
    try:
        instances = source["instances"]
        candidates = source["candidates"]
        evaluator = load_evaluator()
        evaluator_path = Path(evaluator.__file__).resolve()
        expected_evaluator_path = (CACHE / "ifbench" / "evaluation_lib.py").resolve()
        if evaluator_path != expected_evaluator_path:
            raise RuntimeError(f"official evaluator imported from unexpected path: {evaluator_path}")
        instance_by_id = {row["id"]: row for row in instances}
        values = official_check_many(
            [(instance_by_id[candidate["prompt_id"]], candidate["text"])
             for candidate in candidates],
            workers=diagnostic_parameters["evaluator_workers"],
        )
        labels = [{
            "candidate_id": candidate["candidate_id"],
            "prompt_id": candidate["prompt_id"], "gold_pass": bool(value),
        } for candidate, value in zip(candidates, values, strict=True)]
        if len(labels) != EXPECTED_CANDIDATES:
            raise RuntimeError("official evaluator cardinality mismatch")
        labels_path = destination / "candidate_labels.jsonl"
        _atomic_jsonl(labels_path, labels)
        result = analyze(
            instances, candidates, source["observations"], labels,
            diagnostic_parameters=diagnostic_parameters,
            source_gate_failures=set(source["source_gate_failures"]),
        )
        outputs = {
            "family_summary.jsonl": result["family_rows"],
            "prompt_summary.jsonl": result["prompt_rows"],
            "temperature_pairs.jsonl": result["temperature_rows"],
            "rule_summary.jsonl": result["rule_rows"],
            "root_causes.jsonl": result["root_causes"],
        }
        for name, rows in outputs.items():
            _atomic_jsonl(destination / name, rows)
        summary = {
            "schema_version": 1, "protocol": PROTOCOL,
            "diagnostic_id": diagnostic_id, "source_run_id": source_run_id,
            "retrospective_after_design_failure": True,
            "posthoc_nonconfirmatory": True, "test_rows_read": False,
            "must_not_inform_v4_claims": True,
            "must_not_reuse_v4_labels_or_candidates": True,
            "scope": {"splits": ["calibration", "dev"],
                      "instances": len(instances), "candidates": len(candidates)},
            "bootstrap": result["bootstrap"], "thresholds": THRESHOLDS,
            "source_blocker_counts": dict(Counter(
                cause for row in result["root_causes"]
                for cause in row["blocking_causes"]
            )),
            "posthoc_signal_counts": dict(Counter(
                signal for row in result["root_causes"]
                for signal in row["posthoc_signals"]
            )),
            "source_gate_failed_families": source["source_gate_failures"],
            "interpretation_limits": {
                "class_support_only_rules_out_class_imbalance": True,
                "token_cap_analysis_is_association_with_official_validity_only": True,
                "semantic_answer_completeness_was_not_evaluated": True,
            },
        }
        _atomic_json(destination / "summary.json", summary)
        report_path = destination / "REPORT.md"
        _atomic_text(report_path, _report_markdown(result))
        after_evaluator_hashes = _validate_evaluator(source["manifest"])
        if after_evaluator_hashes != source["evaluator_hashes"]:
            raise RuntimeError("official evaluator dependencies changed during evaluation")
        after = _tree_hashes(source["source"])
        if after != source["source_hashes"]:
            raise RuntimeError("failed source run changed during diagnostic evaluation")
        output_hashes = {name: file_hash(destination / name) for name in OUTPUT_NAMES}
        _atomic_json(destination / "manifest.json", {
            **identity, "diagnostic_id": diagnostic_id,
            "source_tree_hashes_before_and_after": source["source_hashes"],
            "output_hashes": output_hashes,
            "cache": {"format": "official_evaluator.sqlite3",
                      "path": str(CACHE / "official_evaluator.sqlite3")},
        })
        _atomic_json(destination / "DIAGNOSTIC_STATE.json", {
            "diagnostic_id": diagnostic_id, "source_run_id": source_run_id,
            "state": "COMPLETE", "retrospective_after_design_failure": True,
            "manifest_sha256": file_hash(destination / "manifest.json"),
        })
        return destination
    except BaseException as exc:
        _atomic_json(destination / "DIAGNOSTIC_STATE.json", {
            "diagnostic_id": diagnostic_id, "source_run_id": source_run_id,
            "state": "FAILED", "error_type": type(exc).__name__,
            "message": str(exc), "retrospective_after_design_failure": True,
        })
        raise
