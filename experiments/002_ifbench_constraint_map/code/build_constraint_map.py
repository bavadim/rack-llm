#!/usr/bin/env python3
"""Classify IFBench instruction ids into hard/soft experiment subsets."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
EXPERIMENT_DATA_DIR = EXPERIMENT_DIR / "data"
ROOT_DATA_DIR = REPO_ROOT / "data"

SNAPSHOT_PATH = ROOT_DATA_DIR / "ifbench_snapshot.jsonl"
MAP_NAME = "ifbench_constraint_map.json"

HARD_SUPPORTED = {
    "format:options": (
        "build_hard_options",
        "fixed option set; can be represented as a finite select/choice",
    ),
    "format:output_template": (
        "build_hard_output_template",
        "template-shaped output can be represented structurally when placeholders are bounded",
    ),
    "format:no_whitespace": (
        "build_hard_no_whitespace",
        "regular language over non-whitespace tokens",
    ),
    "format:title_case": (
        "build_hard_title_case",
        "regular title-case approximation; agreement validation must check verifier details",
    ),
    "format:newline": (
        "build_hard_newline",
        "newline placement is structural when row kwargs expose the required count",
    ),
    "format:list": (
        "build_hard_list",
        "list markers and separators are structural; row-level builder may reject underspecified rows",
    ),
    "format:sub-bullets": (
        "build_hard_sub_bullets",
        "nested bullet indentation is structural with bounded depth",
    ),
    "format:no_bullets_bullets": (
        "build_hard_no_bullets_bullets",
        "mixed bullet/no-bullet line structure can be bounded and checked",
    ),
    "format:line_indent": (
        "build_hard_line_indent",
        "indentation pattern is structural",
    ),
    "format:quote_unquote": (
        "build_hard_quote_unquote",
        "quote/explanation layout can be bounded structurally",
    ),
    "format:parentheses": (
        "build_hard_parentheses",
        "balanced parentheses can be generated with bounded nesting",
    ),
    "format:quotes": (
        "build_hard_quotes",
        "nested quotes can be generated with bounded nesting",
    ),
    "custom:csv_city": (
        "build_hard_csv_city",
        "CSV surface form is structural; hidden city requirements are validated row-level",
    ),
    "custom:csv_special_character": (
        "build_hard_csv_special_character",
        "CSV delimiter/character constraints are structural",
    ),
    "custom:csv_quotes": (
        "build_hard_csv_quotes",
        "CSV quote placement is structural",
    ),
    "custom:date_format_list": (
        "build_hard_date_format_list",
        "date-list format is a bounded regex-style structural constraint",
    ),
    "repeat:repeat_simple": (
        "build_hard_repeat_simple",
        "repeat target can be structural when extractable from prompt/kwargs",
    ),
    "repeat:repeat_span": (
        "build_hard_repeat_span",
        "span repetition can be structural when extractable from prompt/kwargs",
    ),
    "repeat:repeat_change": (
        "build_hard_repeat_change",
        "changed repetition can be structural when the transformation is explicit",
    ),
}

SOFT_SUPPORTED = {
    "count:keywords_multiple": (
        "build_soft_keywords_multiple",
        "keyword presence/count hints produce useful incomplete watchers",
    ),
    "count:conjunctions": (
        "build_soft_conjunctions",
        "conjunction lists produce local positive/negative regex watchers",
    ),
    "count:numbers": (
        "build_soft_numbers",
        "digit-like patterns produce simple incomplete count watchers",
    ),
    "count:punctuation": (
        "build_soft_punctuation",
        "punctuation presence produces simple local watchers",
    ),
    "sentence:keyword": (
        "build_soft_sentence_keyword",
        "keyword presence is directly observable but intentionally incomplete",
    ),
    "words:keywords_specific_position": (
        "build_soft_keywords_specific_position",
        "keyword and approximate position hints can be weak watchers",
    ),
    "words:words_position": (
        "build_soft_words_position",
        "target word and approximate position hints can be weak watchers",
    ),
    "format:list": (
        "build_soft_list",
        "list markers and line counts provide useful soft structural signals",
    ),
    "format:sub-bullets": (
        "build_soft_sub_bullets",
        "indented bullet markers provide useful soft structural signals",
    ),
    "format:no_bullets_bullets": (
        "build_soft_no_bullets_bullets",
        "bullet mixture can be approximated with weak line-structure watchers",
    ),
    "format:options": (
        "build_soft_options",
        "option strings can be rewarded without enforcing a closed choice",
    ),
    "format:no_whitespace": (
        "build_soft_no_whitespace",
        "whitespace penalties/rewards can be expressed as weak watchers",
    ),
    "format:title_case": (
        "build_soft_title_case",
        "title-case word patterns can be rewarded approximately",
    ),
    "repeat:repeat_simple": (
        "build_soft_repeat_simple",
        "repeat target presence can be rewarded approximately",
    ),
    "repeat:repeat_span": (
        "build_soft_repeat_span",
        "span presence/repetition can be rewarded approximately",
    ),
    "repeat:repeat_change": (
        "build_soft_repeat_change",
        "changed span hints can be rewarded approximately",
    ),
    "custom:csv_city": (
        "build_soft_csv_city",
        "CSV separators and row shape provide weak structural signals",
    ),
    "custom:csv_special_character": (
        "build_soft_csv_special_character",
        "special-character CSV shape provides weak structural signals",
    ),
    "custom:csv_quotes": (
        "build_soft_csv_quotes",
        "quote-heavy CSV shape provides weak structural signals",
    ),
    "custom:date_format_list": (
        "build_soft_date_format_list",
        "date regexes and list separators provide weak structural signals",
    ),
}

EXCLUSION_REASONS_BY_FAMILY = {
    "ratio": "requires semantic ratio/count evaluation beyond simple structural watchers",
    "words": "requires linguistic or global word-order analysis outside DSL v1 soft/hard scope",
    "sentence": "requires sentence-level semantic or linguistic analysis outside selected soft ids",
    "count": "requires exact semantic counting or entity detection outside selected soft ids",
    "format": "format family not selected for hard/soft subsets or needs specialized verifier",
    "custom": "custom verifier is not selected for reproducible hard/soft subsets",
    "repeat": "repeat form is not selected for reproducible hard/soft subsets",
}


def read_snapshot(path: Path) -> list[dict]:
    if not path.exists():
        raise FileNotFoundError(
            f"{path} does not exist; run experiments/001_ifbench_snapshot first"
        )
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def family_of(instruction_id: str) -> str:
    return instruction_id.split(":", 1)[0]


def build_map(rows: list[dict]) -> dict[str, dict]:
    counts = Counter(
        instruction_id
        for row in rows
        for instruction_id in row["instruction_id_list"]
    )
    result: dict[str, dict] = {}
    for instruction_id in sorted(counts):
        family = family_of(instruction_id)
        hard_builder, hard_reason = HARD_SUPPORTED.get(instruction_id, (None, None))
        soft_builder, soft_reason = SOFT_SUPPORTED.get(instruction_id, (None, None))
        reasons = []
        if hard_reason:
            reasons.append(f"hard: {hard_reason}")
        if soft_reason:
            reasons.append(f"soft: {soft_reason}")
        if not reasons:
            reasons.append(
                EXCLUSION_REASONS_BY_FAMILY.get(
                    family,
                    "not selected for the hard or soft experimental subsets",
                )
            )
        builder_task = hard_builder or soft_builder
        result[instruction_id] = {
            "family": family,
            "hard_supported": hard_builder is not None,
            "soft_supported": soft_builder is not None,
            "hard_builder": hard_builder,
            "soft_builder": soft_builder,
            "builder_task": builder_task,
            "snapshot_count": counts[instruction_id],
            "reason": "; ".join(reasons),
        }
    return result


def write_outputs(constraint_map: dict[str, dict], output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        with (output_dir / MAP_NAME).open("w", encoding="utf-8") as handle:
            json.dump(constraint_map, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--experiment-only",
        action="store_true",
        help="write only experiments/002_ifbench_constraint_map/data artifacts",
    )
    args = parser.parse_args(argv)

    rows = read_snapshot(SNAPSHOT_PATH)
    constraint_map = build_map(rows)
    output_dirs = [EXPERIMENT_DATA_DIR]
    if not args.experiment_only:
        output_dirs.append(ROOT_DATA_DIR)
    write_outputs(constraint_map, output_dirs)
    print(
        json.dumps(
            {
                "instruction_ids": len(constraint_map),
                "hard_supported": sum(
                    1 for item in constraint_map.values() if item["hard_supported"]
                ),
                "soft_supported": sum(
                    1 for item in constraint_map.values() if item["soft_supported"]
                ),
                "outputs": [str(path) for path in output_dirs],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
