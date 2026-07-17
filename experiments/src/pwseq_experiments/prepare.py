from __future__ import annotations

import hashlib
import json
import math
import random
import re
import shutil
import string
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .builders import SOFT_FAMILIES, build, empty_kwargs
from .common import CACHE, DATA, SOURCE_DATA, file_hash, load_config, read_jsonl, stable_hash, write_json, write_jsonl

TEST_MARKERS = [f"TEST-{i:02d}>" for i in range(25)]
CONSTRAINT_TEXT = {
    "format:sub-bullets": "Your response must include bullet points denoted by * and at least one sub-bullet point denoted by - for each bullet point.",
    "format:newline": "Write each word on a new line.",
    "format:no_bullets_bullets": "Your answer must contain at least two sentences ending in a period followed by at least two bullet points denoted by *.",
    "format:emoji": "Please use an emoji at the end of every sentence.",
    "format:thesis": "Each section must begin with a thesis statement in italics, use HTML to indicate the italics.",
    "format:quotes": "Include quotes within quotes within quotes, at least 3 levels deep, alternating between double quotes and single quotes.",
    "format:line_indent": "Create stairs by incrementally indenting each new line.",
}
TOPIC_LEFT = [
    "fault diagnosis", "water reuse", "archival preservation", "sensor fusion", "urban logistics",
    "community mediation", "battery safety", "curriculum review", "privacy auditing", "habitat mapping",
    "incident communication", "prototype testing", "supply resilience", "laboratory scheduling", "energy forecasting",
    "accessibility testing", "maintenance triage", "survey design", "coastal monitoring", "software observability",
    "public consultation", "materials screening", "data stewardship", "risk registers", "knowledge transfer",
]
TOPIC_RIGHT = [
    "for a small organization", "under uncertain demand", "with limited staff", "for non-specialists",
    "in a regulated setting", "across distributed teams", "with noisy measurements", "during a pilot",
    "for long-term planning", "with transparent assumptions", "under a fixed budget", "for classroom use",
]
PROMPT_FORMS = [
    "Explain {topic}, covering the mechanism, a practical example, and one limitation.",
    "Write a concise decision memo about {topic}, including benefits, risks, and a next step.",
    "Compare two approaches to {topic} and state when each is appropriate.",
    "Propose a small evaluation plan for {topic}, with measures, success criteria, and a failure mode.",
    "Prepare a teaching note about {topic}, including a misconception and a caution.",
]


def _keyword(index: int) -> str:
    letters = []
    value = index
    for _ in range(3):
        letters.append(string.ascii_lowercase[value % 26])
        value //= 26
    return "zx" + "".join(reversed(letters))


def _base_prompt(index: int) -> str:
    topic = f"{TOPIC_LEFT[index % len(TOPIC_LEFT)]} {TOPIC_RIGHT[(index // len(TOPIC_LEFT)) % len(TOPIC_RIGHT)]}"
    return PROMPT_FORMS[(index * 7) % len(PROMPT_FORMS)].format(topic=topic)


def _used_parameter_values(rows: list[dict[str, Any]]) -> dict[tuple[str, str], set[Any]]:
    used: dict[tuple[str, str], set[Any]] = defaultdict(set)
    for row in rows:
        for key, value in row["kwargs"][0].items():
            if value is not None:
                used[(row["family"], key)].add(json.dumps(value, sort_keys=True))
    return used


def _word_ranges(used: dict[tuple[str, str], set[Any]]) -> list[tuple[int, int]]:
    mins = {json.loads(x) for x in used[("count:word_count_range", "min_words")]}
    maxs = {json.loads(x) for x in used[("count:word_count_range", "max_words")]}
    pairs = []
    for lo in range(46, 181):
        for width in (8, 10, 12):
            hi = lo + width
            if lo not in mins and hi not in maxs:
                pairs.append((lo, hi))
    return pairs[:25]


def _constraint(family: str, index: int, used: dict[tuple[str, str], set[Any]]) -> tuple[str, dict[str, Any]]:
    if family == "count:keywords_multiple":
        words = [_keyword(index * 5 + j) for j in range(5)]
        text = (
            f"Include keyword {words[0]} once in your response, keyword {words[1]} twice in your response, "
            f"keyword {words[2]} three times in your response, keyword {words[3]} five times in your response, "
            f"and keyword {words[4]} seven times in your response."
        )
        return text, empty_kwargs(**{f"keyword{i + 1}": value for i, value in enumerate(words)})
    if family == "count:conjunctions":
        n = 6 + index % 2
        return f"Use at least {n} different coordinating conjunctions in the response.", empty_kwargs(small_n=float(n))
    if family == "count:numbers":
        n = 10 + index % 3
        return f"Include exactly {n} numbers in the response.", empty_kwargs(N=float(n))
    if family == "count:word_count_range":
        lo, hi = _word_ranges(used)[index]
        return f"The response must contain between {lo} and {hi} words.", empty_kwargs(min_words=lo, max_words=hi)
    if family == "format:list":
        marker = TEST_MARKERS[index]
        return f"Answer with a list of items, instead of bullet points use {marker}.", empty_kwargs(sep=marker)
    return CONSTRAINT_TEXT[family], empty_kwargs()


def build_test_generated(calibration: list[dict[str, Any]], dev: list[dict[str, Any]], per_family: int) -> list[dict[str, Any]]:
    used = _used_parameter_values(calibration + dev)
    existing_prompts = {row["prompt"] for row in calibration + dev}
    rows: list[dict[str, Any]] = []
    base_index = 0
    for family_index, family in enumerate(SOFT_FAMILIES):
        for index in range(per_family):
            while _base_prompt(base_index) in existing_prompts:
                base_index += 1
            base_prompt = _base_prompt(base_index)
            base_index += 1
            description, kwargs = _constraint(family, index, used)
            position = "prefix" if (family_index + index) % 2 == 0 else "suffix"
            prompt = f"{description}\n{base_prompt}" if position == "prefix" else f"{base_prompt}\n{description}"
            max_tokens = 512 if family in {"count:word_count_range", "format:newline"} else 384
            spec = build(family, kwargs, max_tokens)
            rows.append({
                "id": f"test-generated-{family.replace(':', '-')}-{index:03d}",
                "split": "test_generated",
                "family": family,
                "prompt": prompt,
                "instruction_id_list": [family],
                "kwargs": [kwargs],
                "max_tokens": max_tokens,
                "hard_spec": spec.hard_spec,
                "weak_rules": spec.weak_rules,
            })
    return rows


def _official_source() -> Path:
    path = CACHE / "ifbench" / "data" / "IFBench_test.jsonl"
    if path.exists():
        return path
    raise FileNotFoundError("official IFBench source is unavailable; bootstrap did not materialize it")


def build_official() -> list[dict[str, Any]]:
    source = read_jsonl(_official_source())
    rows = []
    for original in source:
        ids = list(original["instruction_id_list"])
        kwargs_list = list(original["kwargs"])
        if len(ids) != 1 or len(kwargs_list) != 1 or ids[0] not in SOFT_FAMILIES:
            continue
        family = ids[0]
        kwargs = dict(kwargs_list[0])
        max_tokens = 512
        spec = build(family, kwargs, max_tokens)
        key = str(original.get("key", original.get("source_key", original.get("id"))))
        rows.append({
            "id": f"test-official-{key}",
            "split": "test_official",
            "family": family,
            "source_key": key,
            "prompt": original["prompt"],
            "instruction_id_list": ids,
            "kwargs": kwargs_list,
            "max_tokens": max_tokens,
            "hard_spec": spec.hard_spec,
            "weak_rules": spec.weak_rules,
        })
    counts = Counter(row["family"] for row in rows)
    missing = set(SOFT_FAMILIES) - set(counts)
    if missing:
        raise RuntimeError(f"official subset missing families: {sorted(missing)}")
    return rows


def rebuild_source_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Drop the legacy serialized DSL and apply the frozen builders afresh."""
    rebuilt = []
    for source in rows:
        spec = build(source["family"], source["kwargs"][0], source["max_tokens"])
        rebuilt.append({
            **{key: value for key, value in source.items()
               if key not in {"rack_llm_spec", "hard_spec", "weak_rules"}},
            "hard_spec": spec.hard_spec,
            "weak_rules": spec.weak_rules,
        })
    return rebuilt


def _remove_boundaries(pattern: str) -> str:
    replacements = [
        ("(^|[^A-Za-z0-9_])", ""), ("([^A-Za-z0-9_]|$)", ""),
        ("(^|[^0-9])", ""), ("([^0-9]|$)", ""),
        ("(^|\\n)", ""), ("[ \\t]*", ""),
    ]
    out = pattern
    for old, new in replacements:
        out = out.replace(old, new)
    return out


def _case_sensitive(pattern: str) -> str:
    return re.sub(r"\[([a-z])([A-Z])\]", lambda m: m.group(1), pattern)


def _corrupt(rules: list[dict[str, Any]], slot: int, mode: str, instance_id: str) -> dict[str, Any] | None:
    original = rules[slot]
    changed = dict(original)
    if mode == "polarity_flip":
        changed["polarity"] = "negative" if original["polarity"] == "positive" else "positive"
    elif mode == "narrow_literal":
        changed["pattern"] = f"PWSEQNOISE{hashlib.sha256((instance_id + str(slot)).encode()).hexdigest()[:16]}"
    elif mode == "over_broad_pattern":
        changed["pattern"] = "(.|\\n)*"
    elif mode == "word_boundary_removal":
        changed["pattern"] = _remove_boundaries(original["pattern"])
    elif mode == "case_sensitivity_error":
        changed["pattern"] = _case_sensitive(original["pattern"])
    elif mode == "duplicate_conflicting_rule":
        donor = rules[(slot + 1) % len(rules)]
        changed["pattern"] = donor["pattern"]
        changed["polarity"] = "negative" if donor["polarity"] == "positive" else "positive"
    else:
        raise KeyError(mode)
    if changed["pattern"] == original["pattern"] and changed["polarity"] == original["polarity"]:
        return None
    return {"slot": slot, "noise_type": mode, "polarity": changed["polarity"], "pattern": changed["pattern"]}


def make_overlay_pair(
    instances: list[dict[str, Any]], seed: int
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    modes = [
        "polarity_flip", "narrow_literal", "over_broad_pattern",
        "word_boundary_removal", "case_sensitivity_error", "duplicate_conflicting_rule",
    ]
    overlays = {0.2: [], 0.4: []}
    for row_index, instance in enumerate(instances):
        rules = instance["weak_rules"]
        rng = random.Random(f"{seed}:{instance['id']}")
        slots = list(range(len(rules)))
        rng.shuffle(slots)
        max_count = max(1, math.floor(len(rules) * .4 + .5))
        chosen = slots[:max_count]
        changes_by_slot = {}
        mode_offset = int(stable_hash({
            "seed": seed, "instance": instance["id"], "purpose": "noise-mode",
        })[:8], 16)
        for offset, slot in enumerate(chosen):
            change = None
            for shift in range(len(modes)):
                mode = modes[(mode_offset + offset + shift) % len(modes)]
                change = _corrupt(rules, slot, mode, instance["id"])
                if change is not None:
                    break
            if change is None:
                raise RuntimeError(f"could not corrupt {instance['id']} slot {slot}")
            changes_by_slot[slot] = change
        for level in (0.2, 0.4):
            count = max(1, math.floor(len(rules) * level + .5))
            selected = chosen[:count]
            changes = [changes_by_slot[slot] for slot in selected]
            overlays[level].append({
                "instance_id": instance["id"],
                "split": instance["split"],
                "noise_level": level,
                "changes": sorted(changes, key=lambda item: item["slot"]),
            })
    return overlays[0.2], overlays[0.4]


def prepare_data() -> dict[str, Any]:
    config = load_config()
    calibration = rebuild_source_rows(read_jsonl(SOURCE_DATA / "calibration.jsonl"))
    dev = rebuild_source_rows(read_jsonl(SOURCE_DATA / "dev.jsonl"))
    hard = [
        {key: value for key, value in row.items() if key != "rack_llm_spec"}
        for row in read_jsonl(SOURCE_DATA / "hard_sanity.jsonl")
    ]
    test_generated = build_test_generated(calibration, dev, int(config["test_per_family"]))
    official = build_official()

    if DATA.exists():
        shutil.rmtree(DATA)
    DATA.mkdir(parents=True)
    for name, rows in [
        ("calibration", calibration), ("dev", dev), ("hard_sanity", hard),
        ("test_generated", test_generated), ("test_official", official),
    ]:
        write_jsonl(DATA / f"{name}.jsonl", rows)
    source_noise20 = read_jsonl(SOURCE_DATA / "noise_20.jsonl")
    source_noise40 = read_jsonl(SOURCE_DATA / "noise_40.jsonl")
    test_noise20, test_noise40 = make_overlay_pair(
        test_generated + official, int(config["dataset_seed"])
    )
    write_jsonl(DATA / "noise_20.jsonl", source_noise20 + test_noise20)
    write_jsonl(DATA / "noise_40.jsonl", source_noise40 + test_noise40)

    instances_by_id = {
        row["id"]: row
        for row in calibration + dev + test_generated + official
    }
    noise_effective = {}
    for level, overlays in [
        (20, source_noise20 + test_noise20),
        (40, source_noise40 + test_noise40),
    ]:
        changes = effective = 0
        for overlay in overlays:
            clean_rules = instances_by_id[overlay["instance_id"]]["weak_rules"]
            for change in overlay["changes"]:
                changes += 1
                clean = clean_rules[change["slot"]]
                effective += (
                    (clean["polarity"], clean["pattern"])
                    != (change["polarity"], change["pattern"])
                )
        noise_effective[str(level)] = {
            "changes": changes,
            "effective_changes": effective,
            "no_op_changes": changes - effective,
        }

    manifest = {
        "dataset": "PWSeq-IFBench",
        "experiment_revision": "2.0.0",
        "seed": config["dataset_seed"],
        "counts": {
            "calibration": len(calibration), "dev": len(dev), "hard_sanity": len(hard),
            "test_generated": len(test_generated), "test_official": len(official),
        },
        "families": SOFT_FAMILIES,
        "files": {
            path.name: file_hash(path)
            for path in sorted(DATA.glob("*.jsonl"))
        },
        "source_v02_hashes": {
            path.name: file_hash(path)
            for path in sorted(SOURCE_DATA.glob("*.jsonl"))
        },
        "builder_contract": "build(family, kwargs, max_tokens)",
        "official_evaluator_phase": "post_generation_only",
        "noise_protocol": (
            "source calibration/dev overlays preserved byte-for-byte by record; "
            "generated test overlays are effective, deterministic, and nested"
        ),
        "noise_effective": noise_effective,
    }
    write_json(DATA / "manifest.json", manifest)
    return manifest
