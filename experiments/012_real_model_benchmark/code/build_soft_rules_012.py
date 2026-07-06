#!/usr/bin/env python3
"""Build paper-grade weak soft rules for Experiment 012."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
SOFT_RULES_DIR = REPO_ROOT / "experiments" / "007_soft_rules" / "code"
SNAPSHOT_PATH = ROOT_DATA_DIR / "ifbench_snapshot.jsonl"
RULES_PATH = ROOT_DATA_DIR / "soft_ifbench_rules.jsonl"
FAILURES_PATH = ROOT_DATA_DIR / "soft_rule_coverage_failures.jsonl"
REPORT_PATH = RESULTS_DIR / "016_soft_rule_coverage_report.json"
GLOBAL_SEED = 1729

sys.path.insert(0, str(SOFT_RULES_DIR))
from soft_rules import build_soft_rules, universal_rules  # noqa: E402


SUPPORTED_FAMILIES = {"count", "format", "sentence", "words", "ratio", "repeat"}


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def family(instruction_id: str) -> str:
    return instruction_id.split(":", 1)[0]


def rule(
    rule_id: str,
    source_instruction_id: str,
    weight: float,
    pattern: str,
    polarity: str,
    description: str,
    *,
    kind: str = "rank",
    noise: bool = False,
    noise_type: str | None = None,
) -> dict[str, Any]:
    return {
        "rule_id": rule_id,
        "source_instruction_id": source_instruction_id,
        "kind": kind,
        "weight": weight,
        "pattern_type": "regex",
        "pattern": pattern,
        "polarity": polarity,
        "noise": noise,
        "noise_type": noise_type,
        "description": description,
    }


def safe_id(text: str) -> str:
    punctuation_names = {
        ".": "period",
        ",": "comma",
        "!": "bang",
        "?": "question",
        ";": "semicolon",
        ":": "colon",
        '"': "double_quote",
        "'": "single_quote",
        "\n": "newline",
        "\t": "tab",
    }
    if text in punctuation_names:
        return punctuation_names[text]
    return re.sub(r"[^a-zA-Z0-9]+", "_", text.strip().lower()).strip("_")[:48] or "x"


def word_boundary(text: str) -> str:
    return rf"(?i)\b{re.escape(text)}\b"


def non_null(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in kwargs.items() if value is not None}


def literal_values(row: dict[str, Any]) -> list[str]:
    values = []
    for kwargs in row.get("kwargs", []):
        for key, value in non_null(kwargs).items():
            if isinstance(value, str) and 2 <= len(value) <= 80 and key not in {"reference_text", "prompt_to_repeat"}:
                values.append(value)
            if isinstance(value, list):
                values.extend(str(item) for item in value if 2 <= len(str(item)) <= 80)
    return list(dict.fromkeys(values))[:8]


def option_values(row: dict[str, Any]) -> list[str]:
    values = []
    for kwargs in row.get("kwargs", []):
        raw = kwargs.get("options") if isinstance(kwargs, dict) else None
        if not isinstance(raw, str):
            continue
        if "/" in raw:
            parts = raw.split("/")
        elif " or " in raw:
            parts = raw.split(" or ")
        elif "," in raw:
            parts = raw.split(",")
        else:
            parts = [raw]
        values.extend(part.strip() for part in parts if part.strip())
    return list(dict.fromkeys(values))[:8]


def numeric_values(row: dict[str, Any]) -> list[int]:
    values = []
    for kwargs in row.get("kwargs", []):
        for value in non_null(kwargs).values():
            if isinstance(value, (int, float)):
                values.append(int(value))
    return values[:6]


def existing_or_generic_rules(row: dict[str, Any], noise_level: float) -> list[dict[str, Any]]:
    generic_clean = universal_hygiene_rules() + generic_surface_rules(row) + prompt_anchor_rules(row) + generic_clean_rules(row)
    try:
        built = [item.to_json() for item in build_soft_rules(row, noise_level)]
        if noise_level == 0.0:
            return dedupe_rules(built + generic_clean)
        target_noise = max(1, math.ceil(len(generic_clean) * noise_level))
        noisy = deterministic_sample(generic_noisy_rules(row), target_noise, row["key"], noise_level)
        return dedupe_rules(built + generic_clean + noisy)
    except Exception:
        pass
    clean = [item.to_json() for item in universal_rules()] + generic_clean
    if noise_level == 0.0:
        return dedupe_rules(clean)
    target_noise = max(1, math.ceil(len(generic_clean) * noise_level))
    noisy = deterministic_sample(generic_noisy_rules(row), target_noise, row["key"], noise_level)
    return dedupe_rules(clean + noisy)


def generic_clean_rules(row: dict[str, Any]) -> list[dict[str, Any]]:
    rules = []
    for instruction_id in row["instruction_id_list"]:
        fam = family(instruction_id)
        rules.extend(FAMILY_BUILDERS.get(fam, generic_family_rules)(row, instruction_id))
    return dedupe_rules(rules)


def universal_hygiene_rules() -> list[dict[str, Any]]:
    return [
        rule("universal_no_think_block_012", "universal", 1.0, r"^(?![\s\S]*</?think>)[\s\S]{1,2000}$", "positive", "reward final answer without visible thinking block"),
        rule("universal_no_chat_tokens_012", "universal", 0.75, r"^(?![\s\S]*<\|(?:im_start|im_end|endoftext)\|>)[\s\S]{1,2000}$", "positive", "reward final answer without chat/special tokens"),
        rule("universal_no_analysis_boilerplate_012", "universal", 0.75, r"(?i)^(?![\s\S]*(thinking process|analyze the request|constraint\s+1|hidden reasoning))[\s\S]+$", "positive", "reward answer without analysis boilerplate"),
        rule("universal_concise_final_answer_012", "universal", 0.5, r"^[\s\S]{1,1200}$", "positive", "reward bounded final answer length"),
    ]


def generic_surface_rules(row: dict[str, Any]) -> list[dict[str, Any]]:
    source = "surface:" + safe_id("_".join(row["instruction_id_list"]))
    return [
        rule(f"{safe_id(source)}_final_medium_no_think_012", source, 0.75, r"(?is)^(?!.*</?think>)(?=.{20,1200}$)[\s\S]+$", "positive", "reward medium-length final answer without thinking block"),
        rule(f"{safe_id(source)}_final_medium_no_analysis_012", source, 0.75, r"(?is)^(?!.*(?:thinking process|analyze the request|hidden reasoning))(?=.{20,1200}$)[\s\S]+$", "positive", "reward medium-length final answer without analysis boilerplate"),
        rule(f"{safe_id(source)}_short_final_no_special_012", source, 0.75, r"(?is)^(?!.*(?:<\\|im_|<\\|endoftext\\|>|</?think>))(?=.{1,600}$)[\s\S]+$", "positive", "reward short final answer without special tokens"),
        rule(f"{safe_id(source)}_paragraph_final_012", source, 0.5, r"(?s)^(?!.*</?think>)(?=.{80,900}$)(?=.*\b[A-Za-z]{4,}\b)[\s\S]+$", "positive", "reward substantive paragraph-like final answer"),
        rule(f"{safe_id(source)}_sentence_pair_012", source, 0.5, r"(?s)[.!?]\s+[A-Z][\s\S]{20,}[.!?]", "positive", "reward multiple sentence surface"),
        rule(f"{safe_id(source)}_numbered_or_bulleted_line_012", source, 0.5, r"(?m)^\s*(?:[-*+]|\d+[.)])\s+\S+", "positive", "reward explicit list line"),
        rule(f"{safe_id(source)}_two_visible_lines_012", source, 0.5, r"(?m)^\S[^\n]{0,120}\n\S", "positive", "reward two compact visible lines"),
        rule(f"{safe_id(source)}_three_line_structure_012", source, 0.5, r"(?m)^(?:.{1,120}\n){2,}.{1,120}$", "positive", "reward three-line structure"),
        rule(f"{safe_id(source)}_alpha_final_short_012", source, 0.5, r"(?is)^(?!.*</?think>)(?=.{1,400}$)(?=.*[A-Za-z]{3})[\s\S]+$", "positive", "reward short alphabetic final answer"),
        rule(f"{safe_id(source)}_alpha_final_long_012", source, 0.5, r"(?is)^(?!.*</?think>)(?=.{400,1800}$)(?=.*[A-Za-z]{3})[\s\S]+$", "positive", "reward long alphabetic final answer"),
        rule(f"{safe_id(source)}_has_terminal_punctuation_012", source, 0.5, r"(?s)[.!?]\s*$", "positive", "reward terminal sentence punctuation"),
        rule(f"{safe_id(source)}_has_digit_surface_012", source, 0.5, r"\b\d+\b", "positive", "reward digit surface"),
        rule(f"{safe_id(source)}_has_quote_surface_012", source, 0.5, r"[\"']", "positive", "reward quote surface"),
        rule(f"{safe_id(source)}_has_colon_semicolon_surface_012", source, 0.5, r"[:;]", "positive", "reward colon or semicolon surface"),
        rule(f"{safe_id(source)}_starts_with_content_012", source, 0.5, r"(?is)^\s*(?!</?think>|<\|)[A-Za-z0-9\"'(*<\-]", "positive", "reward direct answer start"),
        rule(f"{safe_id(source)}_has_uppercase_word_012", source, 0.5, r"\b[A-Z][a-z]{2,}\b", "positive", "reward uppercase-starting content word"),
        rule(f"{safe_id(source)}_has_comma_surface_012", source, 0.5, r",", "positive", "reward comma surface"),
        rule(f"{safe_id(source)}_has_newline_surface_012", source, 0.5, r"\n", "positive", "reward newline surface"),
        rule(f"{safe_id(source)}_five_alpha_words_012", source, 0.5, r"(?:\b[A-Za-z]{3,}\b[\s,.;:!?]*){5,}", "positive", "reward at least five alphabetic words"),
        rule(f"{safe_id(source)}_twenty_alpha_words_012", source, 0.5, r"(?:\b[A-Za-z]{3,}\b[\s,.;:!?]*){20,}", "positive", "reward at least twenty alphabetic words"),
        rule(f"{safe_id(source)}_delimiter_rich_012", source, 0.5, r"(?:[,;:!?()\[\]{}\"'][\s\S]*){4,}", "positive", "reward delimiter-rich answer"),
        rule(f"{safe_id(source)}_one_line_short_answer_012", source, 0.5, r"^[^\n]{1,120}$", "positive", "reward compact one-line answer"),
        rule(f"{safe_id(source)}_one_or_two_word_answer_012", source, 0.5, r"^\W*(?:[A-Za-z0-9-]+\W*){1,2}$", "positive", "reward one- or two-word answer"),
        rule(f"{safe_id(source)}_has_math_symbol_012", source, 0.5, r"[$=+*/\\]|\\b(?:theorem|proof|graph|metric|space)\\b", "positive", "reward math/problem surface cue"),
        rule(f"{safe_id(source)}_all_caps_line_012", source, 0.5, r"(?m)^[A-Z0-9 .,:;()'-]{8,}$", "positive", "reward all-caps/title line surface"),
        rule(f"{safe_id(source)}_thinking_block_negative_012", source, -1.0, r"(?is)</?think>|thinking process|analyze the request", "negative", "penalize visible thinking/analysis block"),
        rule(f"{safe_id(source)}_special_token_negative_012", source, -1.0, r"<\|(?:im_start|im_end|endoftext)\|>", "negative", "penalize visible chat/special tokens"),
        rule(f"{safe_id(source)}_empty_or_tiny_negative_012", source, -1.0, r"^\W*(?:\w+\W*){0,3}$", "negative", "penalize empty or tiny answer"),
    ]


def prompt_anchor_rules(row: dict[str, Any]) -> list[dict[str, Any]]:
    stop = {
        "the",
        "and",
        "that",
        "with",
        "your",
        "response",
        "must",
        "should",
        "include",
        "write",
        "answer",
        "using",
        "given",
        "reference",
        "text",
        "word",
        "sentence",
        "words",
        "ratio",
        "ensure",
        "exactly",
        "only",
        "from",
        "this",
        "what",
        "which",
        "about",
        "will",
        "have",
        "into",
        "than",
        "more",
    }
    words = []
    for match in re.finditer(r"[A-Za-z][A-Za-z'-]{5,}", row.get("prompt", "")):
        word = match.group(0).strip("-'").lower()
        if word and word not in stop and not word.endswith("ing"):
            words.append(word)
    anchors = list(dict.fromkeys(words))[:4]
    source = "prompt:" + safe_id("_".join(row["instruction_id_list"]))
    rules = []
    for index, anchor in enumerate(anchors, start=1):
        rules.append(rule(f"{safe_id(source)}_anchor_{index}_{safe_id(anchor)}_012", source, 0.5, word_boundary(anchor), "positive", f"reward prompt topic anchor {anchor!r}"))
    if len(anchors) >= 2:
        rules.append(rule(f"{safe_id(source)}_two_anchors_012", source, 0.75, rf"{word_boundary(anchors[0])}[\s\S]*{word_boundary(anchors[1])}|{word_boundary(anchors[1])}[\s\S]*{word_boundary(anchors[0])}", "positive", "reward two prompt topic anchors"))
    return rules


def generic_noisy_rules(row: dict[str, Any]) -> list[dict[str, Any]]:
    rules = []
    for instruction_id in row["instruction_id_list"]:
        fam = family(instruction_id)
        values = literal_values(row)
        source = instruction_id
        rules.append(rule(f"noise_{safe_id(source)}_sign_flip_words", source, -1.0, r"\b\w+\b", "negative", "sign flip for generic lexical signal", noise=True, noise_type="sign_flip"))
        rules.append(rule(f"noise_{safe_id(source)}_todo_reward", source, 1.0, r"(?i)\b(todo|unknown|n/a)\b", "positive", "spurious placeholder reward", noise=True, noise_type="spurious"))
        if values:
            first = values[0]
            rules.append(rule(f"noise_{safe_id(source)}_{safe_id(first)}_substring", source, 1.0, re.escape(first[: max(1, len(first) // 2)]), "positive", "substring literal proxy", noise=True, noise_type="substring"))
        if fam in {"count", "ratio"}:
            rules.append(rule(f"noise_{safe_id(source)}_wrong_number", source, 1.0, r"\b(?:42|100|999)\b", "positive", "wrong numeric threshold", noise=True, noise_type="wrong_threshold"))
        if fam == "format":
            rules.append(rule(f"noise_{safe_id(source)}_markdown_anywhere", source, 1.0, r"[-*#]", "positive", "loose markdown marker", noise=True, noise_type="loose_marker"))
        if fam == "words":
            rules.append(rule(f"noise_{safe_id(source)}_single_letter", source, 1.0, r"(?i)\b[a-z]\b", "positive", "single-letter lexical proxy", noise=True, noise_type="weak_proxy"))
    return dedupe_rules(rules)


def count_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    nums = numeric_values(row)
    rules = [
        rule(f"{safe_id(source)}_wordy_response", source, 1.0, r"(?:\b\w+\b[\s,.;:]*){20,}", "positive", "reward substantive word count"),
        rule(f"{safe_id(source)}_very_short", source, -2.0, r"^\W*(?:\w+\W*){0,4}$", "negative", "penalize very short response"),
        rule(f"{safe_id(source)}_has_number_or_list", source, 0.5, r"(?:\b\d+\b|(?m)^\s*\d+[.)])", "positive", "weak count/list numeric signal"),
    ]
    for value in values[:4]:
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}_literal", source, 1.0, word_boundary(value), "positive", f"reward literal {value!r}"))
    for number in nums[:2]:
        rules.append(rule(f"{safe_id(source)}_{number}_threshold_hint", source, 0.5, rf"(?:\b\w+\b[\s,.;:]*){{{max(1, min(number, 20))},}}", "positive", f"weak threshold hint for {number}"))
    if source == "count:numbers" and nums:
        target = max(1, min(nums[0], 25))
        rules.extend(
            [
                rule(f"count_numbers_exact_{target}_digits_012", source, 1.5, rf"^(?:\D*\d){{{target}}}\D*$", "positive", f"reward exactly {target} digit groups"),
                rule(f"count_numbers_at_least_{target}_digits_012", source, 0.75, rf"(?:\b\d+\b[\s\S]*){{{target},}}", "positive", f"reward at least {target} digit groups"),
                rule("count_numbers_numbered_lines_012", source, 0.75, r"(?m)^\s*\d+[.)]\s+\S+", "positive", "reward numbered lines"),
            ]
        )
    if source in {"count:word_count_range", "count:unique_word_count"}:
        thresholds = sorted({max(5, min(number, 80)) for number in nums[:3]} | {10, 20, 40})
        for threshold in thresholds[:5]:
            rules.append(rule(f"{safe_id(source)}_{threshold}_word_span_012", source, 0.5, rf"(?:\b[A-Za-z]+\b[\s,.;:]*){{{threshold},}}", "positive", f"reward at least {threshold} alphabetic words"))
        rules.append(rule(f"{safe_id(source)}_short_answer_012", source, -1.0, r"^\W*(?:\w+\W*){0,8}$", "negative", "penalize very short answer"))
    if source == "count:word_count_range" and len(nums) >= 2:
        lo, hi = sorted(nums[:2])
        if 0 < lo <= hi <= 200:
            rules.append(rule("count_word_count_range_exact_span_012", source, 2.0, rf"^\W*(?:[A-Za-z0-9]+(?:\W+|$)){{{lo},{hi}}}\W*$", "positive", f"reward {lo}-{hi} token response"))
            rules.append(rule("count_word_count_range_too_few_012", source, -1.0, rf"^\W*(?:[A-Za-z0-9]+(?:\W+|$)){{0,{max(0, lo - 1)}}}\W*$", "negative", f"penalize fewer than {lo} tokens"))
            rules.append(rule("count_word_count_range_too_many_012", source, -1.0, rf"^(?:\W*[A-Za-z0-9]+){{{hi + 1},}}[\s\S]*$", "negative", f"penalize more than {hi} tokens"))
    if source == "count:punctuation":
        marks = [(".", r"\."), (",", r","), ("!", r"!"), ("?", r"\?"), (";", r";"), (":", r":")]
        for mark, pattern in marks:
            rules.append(rule(f"count_punctuation_{safe_id(mark)}_present_012", source, 1.0, pattern, "positive", f"reward punctuation {mark!r}"))
        rules.append(rule("count_punctuation_interrobang_012", source, 1.0, r"(?:!\?|\?!|‽)", "positive", "reward interrobang form"))
        rules.append(rule("count_punctuation_many_marks_012", source, 1.0, r"(?s)(?=.*\.)(?=.*,)(?=.*!)(?=.*\?)(?=.*;)(?=.*:).+", "positive", "reward broad punctuation coverage"))
        rules.append(rule("count_punctuation_no_marks_012", source, -1.0, r"^[^.,!?;:]*$", "negative", "penalize absence of common punctuation"))
    if source == "count:pronouns":
        rules.append(rule("count_pronouns_common_012", source, 1.0, r"(?i)\b(i|me|my|mine|you|your|yours|he|him|his|she|her|hers|it|its|we|us|our|they|them|their)\b", "positive", "reward common pronoun"))
        rules.append(rule("count_pronouns_none_012", source, -1.0, r"(?i)^(?!.*\b(i|me|my|you|your|he|she|it|we|they|them|their)\b).*$", "negative", "penalize no common pronoun"))
    if source == "count:person_names":
        rules.append(rule("count_person_names_capitalized_pair_012", source, 1.0, r"\b[A-Z][a-z]{2,}\s+[A-Z][a-z]{2,}\b", "positive", "reward capitalized name-like pair"))
        rules.append(rule("count_person_names_name_list_012", source, 0.75, r"(?i)\b(alex|maria|john|emma|david|sarah|michael|anna|james|linda)\b", "positive", "reward common given-name proxy"))
    if source == "count:words_japanese":
        rules.append(rule("count_japanese_script_012", source, 1.5, r"[\u3040-\u30ff\u3400-\u9fff]", "positive", "reward Japanese/CJK script"))
        rules.append(rule("count_japanese_absent_012", source, -1.0, r"^[^\u3040-\u30ff\u3400-\u9fff]*$", "negative", "penalize absence of Japanese/CJK script"))
    return rules


def format_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    rules = [
        rule(f"{safe_id(source)}_line_structure", source, 1.0, r".+\n.+", "positive", "reward visible line structure"),
        rule(f"{safe_id(source)}_marker_structure", source, 1.0, r"(?m)^\s*(?:[-*+]|\d+[.)]|#+)\s+", "positive", "reward common structural marker"),
        rule(f"{safe_id(source)}_plain_single_line", source, -1.0, r"^[^\n]{0,80}$", "negative", "penalize short single-line answer"),
    ]
    for value in values[:4]:
        escaped = re.escape(value)
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}_literal_012", source, 1.0, escaped, "positive", f"reward literal format token {value!r}"))
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}_repeated_012", source, 0.75, rf"{escaped}[\s\S]*{escaped}", "positive", f"reward repeated format token {value!r}"))
    if source == "format:emoji":
        rules.append(rule("format_emoji_unicode_hint", source, 2.0, r"[\U0001F300-\U0001FAFF]", "positive", "reward emoji codepoint"))
        rules.append(rule("format_emoji_multiple_012", source, 1.0, r"[\U0001F300-\U0001FAFF][\s\S]*[\U0001F300-\U0001FAFF]", "positive", "reward multiple emoji codepoints"))
        rules.append(rule("format_emoji_none_012", source, -1.0, r"^[^\U0001F300-\U0001FAFF]*$", "negative", "penalize emoji-free surface proxy"))
    if source == "format:newline":
        rules.extend(
            [
                rule("format_newline_one_break_012", source, 1.5, r"\n", "positive", "reward newline"),
                rule("format_newline_two_lines_012", source, 1.0, r"(?m)^.+\n.+$", "positive", "reward two visible lines"),
                rule("format_newline_many_short_lines_012", source, 1.0, r"(?m)^(?:[A-Za-z0-9'’-]{1,24})\s*$[\s\S]*^(?:[A-Za-z0-9'’-]{1,24})\s*$[\s\S]*^(?:[A-Za-z0-9'’-]{1,24})\s*$", "positive", "reward multiple short newline-separated items"),
                rule("format_newline_dense_breaks_012", source, 0.75, r"(?:\n[^\n]{1,32}){5,}", "positive", "reward dense line breaks"),
                rule("format_newline_single_line_012", source, -1.0, r"^[^\n]*$", "negative", "penalize single-line response"),
            ]
        )
    if source == "format:line_indent":
        rules.extend(
            [
                rule("format_indent_leading_spaces_012", source, 1.5, r"(?m)^\s{2,}\S", "positive", "reward indented line"),
                rule("format_indent_after_newline_012", source, 1.0, r"\n\s{2,}\S", "positive", "reward newline followed by indentation"),
                rule("format_indent_none_012", source, -1.0, r"(?m)^(?!.*^\s{2,}\S).*$", "negative", "penalize no indented line"),
            ]
        )
    if source == "format:quote_unquote":
        rules.extend(
            [
                rule("format_quote_unquote_double_012", source, 1.0, r'"[^"\n]{2,}"', "positive", "reward quoted span"),
                rule("format_quote_unquote_plain_after_012", source, 0.75, r'"[^"\n]{2,}".+\b[a-zA-Z]{3,}\b', "positive", "reward quoted span plus plain text"),
                rule("format_quote_unquote_many_quotes_012", source, 0.75, r'(?:[^"]*"[^"]*"){2,}', "positive", "reward multiple quote delimiters"),
                rule("format_quote_unquote_quote_then_sentence_012", source, 0.75, r'"[^"\n]{2,}"\s*[A-Za-z][^.!?]{5,}[.!?]', "positive", "reward quote followed by explanatory sentence"),
                rule("format_quote_unquote_balanced_quote_proxy_012", source, 0.75, r'(?s)"[^"]{2,}"[^"]{5,}', "positive", "reward balanced quote plus unquoted continuation proxy"),
                rule("format_quote_unquote_no_adjacent_quotes_012", source, 0.5, r'^(?![\s\S]*""[\s\S]*$)[\s\S]*"[\s\S]+$', "positive", "reward quote text without adjacent empty quotes"),
                rule("format_quote_unquote_no_quote_012", source, -1.0, r'^[^"]*$', "negative", "penalize absence of double quote"),
            ]
        )
    if source == "format:options":
        options = option_values(row)
        if options:
            alternatives = "|".join(re.escape(option) for option in options)
            rules.extend(
                [
                    rule("format_options_clean_exact_choice_012", source, 1.5, rf"(?i)^\s*(?:{alternatives})\s*$", "positive", "reward exact option-only final answer"),
                    rule("format_options_clean_choice_with_punct_012", source, 1.0, rf"(?i)^\s*(?:{alternatives})[.!]?\s*$", "positive", "reward compact option-only answer with optional punctuation"),
                    rule("format_options_explained_choice_negative_012", source, -1.0, rf"(?i)^\s*(?:{alternatives})\b[\s\S]{{20,}}$", "negative", "penalize option followed by explanation"),
                ]
            )
    if source == "format:quotes":
        rules.extend(
            [
                rule("format_quotes_double_012", source, 1.0, r'"[^"\n]{2,}"', "positive", "reward double-quoted span"),
                rule("format_quotes_single_012", source, 0.75, r"'[^'\n]{2,}'", "positive", "reward single-quoted span"),
                rule("format_quotes_many_quote_marks_012", source, 0.75, r"(?:[\"'][\s\S]*){4,}", "positive", "reward many quote marks"),
                rule("format_quotes_alternating_proxy_012", source, 0.75, r'"[^"]*\'[^\']+\'[^"]*"', "positive", "reward single quotes inside double quotes proxy"),
                rule("format_quotes_none_012", source, -1.0, r"^[^\"']*$", "negative", "penalize no quote marks"),
            ]
        )
    if source == "format:parentheses":
        rules.extend(
            [
                rule("format_parentheses_pair_012", source, 1.5, r"\([^()\n]{1,80}\)", "positive", "reward parenthesized span"),
                rule("format_parentheses_brackets_012", source, 0.75, r"[\[\{][^\]\}\n]{1,80}[\]\}]", "positive", "reward bracketed span"),
                rule("format_parentheses_nested_3_012", source, 1.0, r"[\(\[\{][\s\S]{0,160}[\(\[\{][\s\S]{0,160}[\(\[\{]", "positive", "reward nested opening delimiters"),
                rule("format_parentheses_nested_5_012", source, 1.5, r"[\(\[\{][\s\S]{0,120}[\(\[\{][\s\S]{0,120}[\(\[\{][\s\S]{0,120}[\(\[\{][\s\S]{0,120}[\(\[\{]", "positive", "reward five nested opening delimiters"),
                rule("format_parentheses_many_delimiters_012", source, 0.75, r"(?:[\(\)\[\]\{\}][\s\S]*){6,}", "positive", "reward many bracket delimiters"),
                rule("format_parentheses_mixed_delimiters_012", source, 0.75, r"(?s)(?=.*[()])(?=.*[\[\]])(?=.*[{}]).+", "positive", "reward mixed bracket families"),
                rule("format_parentheses_none_012", source, -1.0, r"^[^()[\]{}]*$", "negative", "penalize no bracket-like punctuation"),
            ]
        )
    if source == "format:output_template":
        rules.extend(
            [
                rule("format_template_my_answer_012", source, 1.5, r"(?i)\bMy Answer\s*:", "positive", "reward My Answer label"),
                rule("format_template_my_conclusion_012", source, 1.5, r"(?i)\bMy Conclusion\s*:", "positive", "reward My Conclusion label"),
                rule("format_template_future_outlook_012", source, 1.0, r"(?i)\bFuture Outlook\s*:", "positive", "reward Future Outlook label"),
            ]
        )
    if source == "format:thesis":
        rules.append(rule("format_thesis_statement_hint", source, 1.0, r"(?i)\b(thesis|argue|because|therefore)\b", "positive", "reward thesis-like discourse markers"))
        rules.append(rule("format_thesis_claim_marker_012", source, 1.0, r"(?i)\b(i argue|this essay|the central claim|in conclusion)\b", "positive", "reward thesis/claim phrase"))
        rules.append(rule("format_thesis_html_italics_012", source, 1.5, r"(?is)<(?:i|em)>[^<]{2,}</(?:i|em)>", "positive", "reward HTML italic thesis marker"))
        rules.append(rule("format_thesis_italics_then_text_012", source, 1.0, r"(?is)<(?:i|em)>[^<]{2,}</(?:i|em)>\s*\S", "positive", "reward italic thesis followed by text"))
    if source == "format:sub-bullets":
        rules.extend(
            [
                rule("format_sub_bullets_star_then_dash_012", source, 1.25, r"(?ms)^\s*\*.+?^\s*-", "positive", "reward star bullet followed by dash sub-bullet"),
                rule("format_sub_bullets_two_stars_012", source, 0.75, r"(?ms)^\s*\*[\s\S]*^\s*\*", "positive", "reward multiple top-level star bullets"),
                rule("format_sub_bullets_dash_line_012", source, 0.75, r"(?m)^\s*-\s+\S+", "positive", "reward dash sub-bullet line"),
                rule("format_sub_bullets_star_line_012", source, 0.75, r"(?m)^\s*\*\s+\S+", "positive", "reward star bullet line"),
                rule("format_sub_bullets_nested_marker_pair_012", source, 0.75, r"(?ms)^\s*\*[^\n]*(?:\n\s+-[^\n]*)+", "positive", "reward nested star/dash marker pair"),
            ]
        )
    if source == "format:no_bullets_bullets":
        rules.extend(
            [
                rule("format_mixed_intro_then_star_bullets_012", source, 1.0, r"(?ms)^[^*\n].{10,}\n\s*\*.+\n\s*\*", "positive", "reward prose followed by star bullets"),
                rule("format_mixed_two_sentences_before_bullets_012", source, 0.75, r"(?s)[.!?].{5,}[.!?][\s\S]*\n\s*\*", "positive", "reward sentence prose before bullets"),
            ]
        )
    if source == "format:title_case":
        rules.extend(
            [
                rule("format_title_case_start_words_012", source, 1.0, r"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){2,}\b", "positive", "reward run of title-case words"),
                rule("format_title_case_lowercase_start_negative_012", source, -1.0, r"(?m)^[a-z]", "negative", "penalize lowercase line start"),
            ]
        )
    if source == "format:no_whitespace":
        rules.extend(
            [
                rule("format_no_whitespace_whole_answer_012", source, 1.5, r"^\S+$", "positive", "reward no-whitespace answer"),
                rule("format_no_whitespace_tiny_answer_012", source, 1.0, r"^[A-Za-z0-9./_-]{1,16}$", "positive", "reward compact no-whitespace answer"),
                rule("format_no_whitespace_tiny_with_punct_012", source, 1.0, r"^[A-Za-z0-9./_-]{1,16}[.!?]?$", "positive", "reward compact no-whitespace answer with punctuation"),
                rule("format_no_whitespace_has_space_negative_012", source, -1.0, r"\s", "negative", "penalize whitespace"),
            ]
        )
    return rules


def sentence_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    rules = [
        rule(f"{safe_id(source)}_sentence_punctuation", source, 1.0, r"[.!?]", "positive", "reward sentence punctuation"),
        rule(f"{safe_id(source)}_multiple_sentences", source, 1.0, r"[.!?].+[.!?]", "positive", "reward multiple sentence-like spans"),
        rule(f"{safe_id(source)}_fragment", source, -1.0, r"^[^.!?]{0,40}$", "negative", "penalize short fragment"),
    ]
    for value in values[:3]:
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}", source, 1.0, word_boundary(value), "positive", f"reward literal {value!r}"))
    if source == "sentence:increment":
        rules.append(rule("sentence_increment_digits_012", source, 1.0, r"\b(?:1|one)\b.*\b(?:2|two)\b.*\b(?:3|three)\b", "positive", "reward increasing number sequence"))
        rules.append(rule("sentence_increment_ordinals_012", source, 0.75, r"(?i)\b(first|second|third|next|then|finally)\b", "positive", "reward ordered sentence markers"))
        rules.append(rule("sentence_increment_many_sentences_012", source, 0.75, r"(?:[.!?]\s+){2,}", "positive", "reward multiple sentence spans"))
        rules.append(rule("sentence_increment_short_then_long_012", source, 0.75, r"(?s)^[^.!?]{1,80}[.!?]\s+[^.!?]{20,160}[.!?]", "positive", "reward increasing sentence length proxy"))
    if source == "sentence:alliteration_increment":
        rules.append(rule("sentence_alliteration_repeated_initial_012", source, 0.75, r"(?i)\b([a-z])[a-z]+\s+\1[a-z]+\b", "positive", "reward adjacent repeated initials"))
        rules.append(rule("sentence_alliteration_sequence_012", source, 0.75, r"(?i)\b(first|second|third|fourth|fifth|next)\b", "positive", "reward sequence markers"))
    return rules


def words_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    rules = [
        rule(f"{safe_id(source)}_alphabetic_words", source, 1.0, r"(?i)\b[a-z]{4,}\b", "positive", "reward alphabetic word tokens"),
        rule(f"{safe_id(source)}_many_words", source, 1.0, r"(?:\b[a-zA-Z]+\b[\s,.;:]*){10,}", "positive", "reward multi-word response"),
        rule(f"{safe_id(source)}_non_words", source, -1.0, r"^[\W\d_]+$", "negative", "penalize no alphabetic words"),
    ]
    for value in values[:3]:
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}", source, 1.0, word_boundary(value), "positive", f"reward literal {value!r}"))
    if source == "words:alphabet":
        rules.append(rule("words_alphabet_sequence_012", source, 1.0, r"(?i)\b(?:a\s+b\s+c|abc|alphabet)\b", "positive", "reward alphabet sequence marker"))
    if source == "words:consonants":
        rules.append(rule("words_consonants_dense_012", source, 0.75, r"(?i)\b[b-df-hj-np-tv-z]{3,}[a-z]*\b", "positive", "reward consonant-heavy words"))
        rules.append(rule("words_consonants_no_vowels_012", source, 0.5, r"(?i)\b[b-df-hj-np-tv-z]{4,}\b", "positive", "reward no-vowel token"))
        rules.append(rule("words_consonants_cluster_pair_012", source, 0.75, r"(?i)\b[a-z]*[bcdfghjklmnpqrstvwxyz]{2}[a-z]*\b.*\b[a-z]*[bcdfghjklmnpqrstvwxyz]{2}[a-z]*\b", "positive", "reward multiple consonant-cluster words"))
        rules.append(rule("words_consonants_vowel_only_negative_012", source, -0.75, r"(?i)\b[aeiou]{2,}\b", "negative", "penalize vowel-only tokens"))
    if source == "words:last_first":
        rules.append(rule("words_last_first_chain_012", source, 0.75, r"(?i)\b([a-z])[a-z]*\s+\1[a-z]*\b", "positive", "reward adjacent same initial proxy"))
        rules.append(rule("words_last_first_sentence_chain_012", source, 1.0, r"(?is)\b([a-z]{3,})[.!?]\s+\1\b", "positive", "reward sentence last/first word chain proxy"))
        rules.append(rule("words_last_first_repeated_boundary_012", source, 0.75, r"(?is)\b([a-z]{3,})\W+\1\b", "positive", "reward repeated boundary word proxy"))
    if source == "words:no_consecutive":
        rules.append(rule("words_no_consecutive_same_initial_negative_012", source, -1.25, r"(?i)\b([a-z])[a-z]*\W+\1[a-z]*\b", "negative", "penalize adjacent words sharing first letter"))
        rules.append(rule("words_no_consecutive_clean_word_012", source, 0.5, r"(?i)\b(?![a-z]*([a-z])\1)[a-z]{4,}\b", "positive", "reward word without repeated adjacent letters"))
    if source == "words:odd_even_syllables":
        rules.append(rule("words_syllable_length_mix_012", source, 0.5, r"(?i)\b[a-z]{3,5}\b.*\b[a-z]{6,9}\b", "positive", "reward mixed short/long word lengths"))
    if source == "words:paragraph_last_first":
        rules.append(rule("words_paragraph_break_012", source, 0.75, r"\n\s*\n", "positive", "reward paragraph break"))
        rules.append(rule("words_paragraph_same_start_end_proxy_012", source, 0.75, r"(?ims)^\s*([a-z]{3,})\b[\s\S]*\b\1[.!?]?\s*$", "positive", "reward paragraph-like same start/end word proxy"))
        rules.append(rule("words_paragraph_no_break_012", source, -0.75, r"^[\s\S]*[^\n]\n?[^\n]*$", "negative", "penalize no visible paragraph break"))
    if source == "words:prime_lengths":
        rules.append(rule("words_prime_length_proxy_012", source, 0.75, r"(?i)\b[a-z]{2,3}\b|\b[a-z]{5}\b|\b[a-z]{7}\b", "positive", "reward prime-length token proxy"))
        rules.append(rule("words_prime_lengths_bad_length_negative_012", source, -1.0, r"(?i)\b[a-z]{1}\b|\b[a-z]{4}\b|\b[a-z]{6}\b|\b[a-z]{8}\b|\b[a-z]{9}\b", "negative", "penalize common non-prime word lengths"))
    if source == "words:repeats":
        rules.append(rule("words_repeats_word_again_012", source, 1.0, r"(?i)\b(\w+)\b(?:\W+\w+){0,12}\W+\1\b", "positive", "reward repeated word"))
        rules.append(rule("words_repeats_no_repeat_negative_012", source, -0.75, r"(?i)^(?!.*\b(\w+)\b.*\b\1\b).*$", "negative", "penalize no repeated word"))
    if source == "words:start_verb":
        rules.append(rule("words_start_verb_imperative_012", source, 0.75, r"(?i)^\s*(write|make|create|explain|describe|list|compare|analyze|give|take|use)\b", "positive", "reward imperative verb start"))
        rules.append(rule("words_start_verb_expanded_012", source, 1.0, r"(?i)^\s*(clarify|simplify|prove|show|derive|demonstrate|explain|describe|write|make|create|list|compare|analyze|give|take|use|is)\b", "positive", "reward expanded verb-start proxy"))
        rules.append(rule("words_start_verb_single_verb_answer_012", source, 1.0, r"(?i)^\s*(clarify|simplify|prove|show|derive|demonstrate|explain|describe|write|make|create|list|compare|analyze)\s*[.!]?\s*$", "positive", "reward compact single-verb answer"))
    if source == "words:palindrome":
        rules.append(rule("words_palindrome_short_hint", source, 0.5, r"(?i)\b(level|radar|civic|madam|refer)\b", "positive", "weak common-palindrome hint"))
        rules.append(rule("words_palindrome_two_common_012", source, 0.75, r"(?i)\b(level|radar|civic|madam|refer)\b[\s\S]*\b(level|radar|civic|madam|refer)\b", "positive", "reward two common palindrome tokens"))
        rules.append(rule("words_palindrome_pal_word_list_012", source, 0.5, r"(?i)\b(rotor|kayak|reviver|deified|tenet)\b", "positive", "reward additional common palindrome token"))
    if source == "words:vowel":
        rules.append(rule("words_vowel_dense_hint", source, 0.5, r"(?i)\b\w*[aeiou]{2}\w*\b", "positive", "weak vowel-density hint"))
        rules.append(rule("words_vowel_any_012", source, 0.5, r"(?i)[aeiou]", "positive", "reward vowel presence"))
    return rules


def ratio_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    rules = [
        rule(f"{safe_id(source)}_stop_words", source, 1.0, r"(?i)\b(the|and|of|to|in|that|is|for)\b", "positive", "reward common stop-word signal"),
        rule(f"{safe_id(source)}_sentence_mix", source, 1.0, r"[.!?].{20,}[.!?]", "positive", "reward multi-sentence ratio surface"),
        rule(f"{safe_id(source)}_too_short_for_ratio", source, -1.0, r"^\W*(?:\w+\W*){0,8}$", "negative", "penalize too-short ratio sample"),
    ]
    for value in values[:2]:
        rules.append(rule(f"{safe_id(source)}_{safe_id(value)}_overlap", source, 0.5, word_boundary(value), "positive", f"weak overlap literal {value!r}"))
    if source == "ratio:stop_words":
        rules.append(rule("ratio_stop_words_dense_012", source, 1.0, r"(?i)\b(?:the|and|of|to|in|that|is|for)\b.*\b(?:the|and|of|to|in|that|is|for)\b", "positive", "reward multiple stop words"))
        rules.append(rule("ratio_stop_words_sparse_012", source, 1.0, r"(?i)^(?!(?:.*\b(?:the|and|of|to|in|that|is|for|a|an)\b){8,})[\s\S]{20,1200}$", "positive", "reward sparse common stop words"))
        rules.append(rule("ratio_stop_words_content_words_012", source, 0.75, r"(?i)(?:\b(?!the\b|and\b|of\b|to\b|in\b|that\b|is\b|for\b|a\b|an\b)[a-z]{5,}\b[\s,.;:]*){8,}", "positive", "reward dense content-word surface"))
        rules.append(rule("ratio_stop_words_very_dense_negative_012", source, -1.0, r"(?i)(?:\b(?:the|and|of|to|in|that|is|for|a|an)\b[\s\S]*){12,}", "negative", "penalize very dense stop-word surface"))
    if source == "ratio:sentence_balance":
        rules.append(rule("ratio_sentence_balance_two_sentences_012", source, 1.0, r"[.!?]\s+[A-Z].{10,}[.!?]", "positive", "reward two sentence-like spans"))
        rules.append(rule("ratio_sentence_balance_all_types_012", source, 1.0, r"(?s)(?=.*\.)(?=.*\?)(?=.*!).+", "positive", "reward declarative/interrogative/exclamatory marks"))
        rules.append(rule("ratio_sentence_balance_question_exclaim_012", source, 0.75, r"(?s)(?=.*\?)(?=.*!).+", "positive", "reward question and exclamation marks"))
        rules.append(rule("ratio_sentence_balance_period_question_012", source, 0.75, r"(?s)(?=.*\.)(?=.*\?).+", "positive", "reward declarative and interrogative marks"))
        rules.append(rule("ratio_sentence_balance_missing_type_negative_012", source, -1.0, r"(?s)^(?:(?![?]|!|\.).)*$", "negative", "penalize no sentence type punctuation"))
    if source == "ratio:sentence_type":
        rules.append(rule("ratio_sentence_type_question_012", source, 0.75, r"\?", "positive", "reward question mark sentence type"))
        rules.append(rule("ratio_sentence_type_exclamation_012", source, 0.75, r"!", "positive", "reward exclamation sentence type"))
        rules.append(rule("ratio_sentence_type_two_periods_one_question_012", source, 1.0, r"(?s)(?:\.[\s\S]*){2,}\?", "positive", "reward rough 2:1 declarative/question pattern"))
    if source == "ratio:sentence_words":
        rules.append(rule("ratio_sentence_words_long_sentence_012", source, 0.75, r"(?:\b\w+\b[\s,;:]*){15,}[.!?]", "positive", "reward long sentence proxy"))
    return rules


def repeat_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    values = literal_values(row)
    prompt_to_repeat = None
    for kwargs in row.get("kwargs", []):
        if isinstance(kwargs.get("prompt_to_repeat"), str):
            prompt_to_repeat = kwargs["prompt_to_repeat"]
            break
    if prompt_to_repeat:
        prefix = prompt_to_repeat[: min(32, len(prompt_to_repeat))]
        return [
            rule(f"{safe_id(source)}_repeat_prefix", source, 2.0, re.escape(prefix), "positive", "reward repeated prefix"),
            rule(f"{safe_id(source)}_substantive_repeat", source, 1.0, r"(?:\b\w+\b[\s,.;:]*){8,}", "positive", "reward substantive copied text"),
            rule(f"{safe_id(source)}_meta_intro", source, -1.0, r"(?i)^(sure|here|of course|i can)\b", "negative", "penalize meta intro"),
        ]
    return words_rules(row, source) + [rule(f"{safe_id(source)}_repeat_generic_meta", source, -1.0, r"(?i)^(sure|here)", "negative", "penalize meta intro")]


def generic_family_rules(row: dict[str, Any], source: str) -> list[dict[str, Any]]:
    return words_rules(row, source)


FAMILY_BUILDERS = {
    "count": count_rules,
    "format": format_rules,
    "sentence": sentence_rules,
    "words": words_rules,
    "ratio": ratio_rules,
    "repeat": repeat_rules,
}


def deterministic_sample(candidates: list[dict[str, Any]], n: int, row_key: str, noise_level: float) -> list[dict[str, Any]]:
    if len(candidates) <= n:
        return candidates
    seed_material = f"{GLOBAL_SEED}:{row_key}:{noise_level}:012".encode("utf-8")
    seed = int(hashlib.sha256(seed_material).hexdigest()[:16], 16)
    rng = random.Random(seed)
    shuffled = list(candidates)
    rng.shuffle(shuffled)
    return shuffled[:n]


def dedupe_rules(rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen = set()
    output = []
    for item in rules:
        key = item["rule_id"]
        if key not in seen:
            seen.add(key)
            output.append(item)
    return output


def build_dataset(rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    emitted = []
    failures = []
    for row in rows:
        unsupported = [instruction_id for instruction_id in row["instruction_id_list"] if family(instruction_id) not in SUPPORTED_FAMILIES]
        if unsupported:
            failures.append(
                {
                    "key": row["key"],
                    "instruction_id_list": row["instruction_id_list"],
                    "unsupported_instruction_ids": unsupported,
                    "reason": "custom one-off instruction excluded from soft weak watcher scope",
                }
            )
            continue
        rule_sets = {
            "clean": existing_or_generic_rules(row, 0.0),
            "noisy_20": existing_or_generic_rules(row, 0.2),
            "noisy_40": existing_or_generic_rules(row, 0.4),
        }
        emitted.append(
            {
                "key": row["key"],
                "prompt": row["prompt"],
                "instruction_id_list": row["instruction_id_list"],
                "kwargs": row["kwargs"],
                "rule_sets": rule_sets,
                "rule_source": "experiment_012_weak_watchers_no_verifier",
            }
        )
    by_family = Counter(family(instruction_id) for row in emitted for instruction_id in row["instruction_id_list"])
    report = {
        "soft_supported_rows": len(emitted),
        "coverage_failures": len(failures),
        "families": dict(sorted(by_family.items())),
        "custom_excluded_rows": len({failure["key"] for failure in failures}),
        "noise_levels": ["clean", "noisy_20", "noisy_40"],
        "builder_imports_official_verifier": False,
    }
    return emitted, failures, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--experiment-only", action="store_true")
    args = parser.parse_args(argv)
    dataset, failures, report = build_dataset(read_jsonl(SNAPSHOT_PATH))
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    if not args.experiment_only:
        write_jsonl(RULES_PATH, dataset)
        write_jsonl(FAILURES_PATH, failures)
    write_jsonl(EXPERIMENT_DIR / "results" / "soft_ifbench_rules_012.jsonl", dataset)
    write_jsonl(EXPERIMENT_DIR / "results" / "soft_rule_coverage_failures_012.jsonl", failures)
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
