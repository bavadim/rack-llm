#!/usr/bin/env python3
"""Build clean/noisy soft rule sets for IFBench rows."""

from __future__ import annotations

import hashlib
import json
import math
import random
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


SUPPORTED_NOISE = {0.0, 0.2, 0.4}
GLOBAL_SEED = 1729


@dataclass(frozen=True)
class RuleSpec:
    rule_id: str
    source_instruction_id: str
    kind: str
    weight: float
    pattern_type: str
    pattern: str
    polarity: str
    noise: bool
    noise_type: str | None
    description: str

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


def build_soft_rules(row: dict, noise_level: float) -> list[RuleSpec]:
    if noise_level not in SUPPORTED_NOISE:
        raise ValueError(f"noise_level must be one of {sorted(SUPPORTED_NOISE)}")
    clean = universal_rules() + row_clean_rules(row)
    if noise_level == 0.0:
        return clean
    noisy_candidates = row_noisy_rules(row)
    clean_non_universal = [rule for rule in clean if not rule.rule_id.startswith("universal_")]
    target_noise = max(1, math.ceil(len(clean_non_universal) * noise_level))
    chosen = deterministic_sample(noisy_candidates, target_noise, row["key"], noise_level)
    return clean + chosen


def universal_rules() -> list[RuleSpec]:
    return [
        rank(
            "universal_refusal_soft_negative",
            "universal",
            -3.0,
            r"(?i)\b(as an ai|i cannot|i can't|unable to|sorry)\b",
            "regex",
            "negative",
            "penalize refusal boilerplate",
        ),
        rank(
            "universal_placeholder_soft_negative",
            "universal",
            -4.0,
            r"(?i)(TODO|\[citation needed\]|unknown|null|n/a)",
            "regex",
            "negative",
            "penalize placeholder text",
        ),
        ban(
            "universal_secret_hard_ban",
            "universal",
            r"(?i)(private key|api[_ -]?key|secret token)",
            "regex",
            "hard veto for obvious secret leakage",
        ),
    ]


def row_clean_rules(row: dict) -> list[RuleSpec]:
    rules: list[RuleSpec] = []
    for instruction_id, kwargs in zip(row["instruction_id_list"], row["kwargs"]):
        builder = CLEAN_BUILDERS.get(instruction_id)
        if builder:
            rules.extend(builder(row, non_null(kwargs)))
    return rules


def row_noisy_rules(row: dict) -> list[RuleSpec]:
    rules: list[RuleSpec] = []
    for instruction_id, kwargs in zip(row["instruction_id_list"], row["kwargs"]):
        builder = NOISY_BUILDERS.get(instruction_id)
        if builder:
            rules.extend(builder(row, non_null(kwargs)))
    if not rules:
        rules.append(noisy_rank("generic_noise_any_punctuation", row["instruction_id_list"][0], 1.0, r"[!?]", "regex", "spurious punctuation reward"))
    return rules


def non_null(kwargs: dict) -> dict:
    return {key: value for key, value in kwargs.items() if value is not None}


def deterministic_sample(candidates: list[RuleSpec], n: int, row_key: str, noise_level: float) -> list[RuleSpec]:
    if len(candidates) <= n:
        return candidates
    seed_material = f"{GLOBAL_SEED}:{row_key}:{noise_level}".encode("utf-8")
    seed = int(hashlib.sha256(seed_material).hexdigest()[:16], 16)
    rng = random.Random(seed)
    indexed = list(candidates)
    rng.shuffle(indexed)
    return indexed[:n]


def safe_id(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]+", "_", text.strip().lower()).strip("_")[:48] or "x"


def word_boundary(pattern: str, ignore_case: bool = True) -> str:
    escaped = re.escape(pattern)
    prefix = "(?i)" if ignore_case else ""
    return rf"{prefix}\b{escaped}\b"


def rank(rule_id, source_id, weight, pattern, pattern_type, polarity, description, *, noise=False, noise_type=None):
    return RuleSpec(rule_id, source_id, "rank", weight, pattern_type, pattern, polarity, noise, noise_type, description)


def ban(rule_id, source_id, pattern, pattern_type, description, *, noise=False, noise_type=None):
    return RuleSpec(rule_id, source_id, "ban", float("-inf"), pattern_type, pattern, "negative", noise, noise_type, description)


def noisy_rank(rule_id, source_id, weight, pattern, pattern_type, description, polarity="positive", noise_type="synthetic_noise"):
    return rank(rule_id, source_id, weight, pattern, pattern_type, polarity, description, noise=True, noise_type=noise_type)


def clean_keywords_multiple(row, kwargs):
    rules = []
    keywords = [kwargs.get(f"keyword{i}") for i in range(1, 6) if kwargs.get(f"keyword{i}")]
    for idx, keyword in enumerate(keywords, start=1):
        kid = safe_id(keyword)
        rules.append(rank(f"kw_multi_{idx}_{kid}_present", "count:keywords_multiple", 1.0, word_boundary(keyword), "regex", "positive", f"reward if keyword {keyword!r} appears"))
        if idx > 1:
            rules.append(rank(f"kw_multi_{idx}_{kid}_twice_hint", "count:keywords_multiple", 0.5, rf"{word_boundary(keyword)}.*{word_boundary(keyword)}", "regex", "positive", f"weak reward if keyword {keyword!r} appears at least twice"))
    if keywords:
        absent_pattern = "|".join(re.escape(k) for k in keywords)
        rules.append(rank("kw_multi_any_required_keyword_present", "count:keywords_multiple", -1.0, rf"(?i)^(?!.*\b(?:{absent_pattern})\b).*$", "regex", "negative", "penalize if all required keywords are absent"))
    return rules


def noisy_keywords_multiple(row, kwargs):
    rules = []
    keywords = [kwargs.get(f"keyword{i}") for i in range(1, 6) if kwargs.get(f"keyword{i}")]
    for keyword in keywords:
        kid = safe_id(keyword)
        rules.append(noisy_rank(f"noise_kw_{kid}_plural", "count:keywords_multiple", 1.0, word_boundary(keyword + "s"), "regex", f"wrong inflection for {keyword}", noise_type="wrong_inflection"))
        rules.append(noisy_rank(f"noise_kw_{kid}_substring", "count:keywords_multiple", 1.0, re.escape(keyword), "regex", f"substring match without word boundaries for {keyword}", noise_type="substring"))
    if keywords:
        rules.append(noisy_rank(f"noise_kw_{safe_id(keywords[0])}_sign_flip", "count:keywords_multiple", -1.0, word_boundary(keywords[0]), "regex", "sign flip for true keyword", polarity="negative", noise_type="sign_flip"))
    return rules


def clean_conjunctions(row, kwargs):
    conjunctions = ["and", "but", "for", "nor", "or", "so", "yet"]
    rules = [rank(f"conj_{c}_present", "count:conjunctions", 1.0, word_boundary(c), "regex", "positive", f"reward conjunction {c}") for c in conjunctions]
    if "small_n" in kwargs:
        rules.append(rank("conj_threshold_hint", "count:conjunctions", 2.0, r"(?i)\b(and|but|for|nor|or|so|yet)\b", "regex", "positive", f"weak threshold hint for at least {int(kwargs['small_n'])} conjunctions"))
    rules.append(rank("conj_none_present", "count:conjunctions", -1.0, r"(?i)^(?!.*\b(and|but|for|nor|or|so|yet)\b).*$", "regex", "negative", "penalize if no coordinating conjunction appears"))
    return rules


def noisy_conjunctions(row, kwargs):
    return [
        noisy_rank("noise_conj_then", "count:conjunctions", 1.0, word_boundary("then"), "regex", "treat then as conjunction", noise_type="wrong_conjunction"),
        noisy_rank("noise_conj_however", "count:conjunctions", 1.0, word_boundary("however"), "regex", "treat however as conjunction", noise_type="wrong_conjunction"),
        noisy_rank("noise_conj_and_sign_flip", "count:conjunctions", -1.0, word_boundary("and"), "regex", "conflicting penalty for and", polarity="negative", noise_type="sign_flip"),
    ]


def clean_numbers(row, kwargs):
    n = int(kwargs.get("N", 2) or 2)
    return [
        rank("numbers_any_digit", "count:numbers", 1.0, r"\b\d+(?:\.\d+)?\b", "regex", "positive", "reward any digit sequence"),
        rank("numbers_two_digit_sequences", "count:numbers", 1.0, r"\b\d+(?:\.\d+)?\b.*\b\d+(?:\.\d+)?\b", "regex", "positive", "reward at least two digit sequences"),
        rank("numbers_none", "count:numbers", -1.0, r"^(?!.*\b\d+(?:\.\d+)?\b).*$", "regex", "negative", f"penalize if no digit-like token appears; target N is {n}"),
    ]


def noisy_numbers(row, kwargs):
    return [
        noisy_rank("noise_numbers_spelled", "count:numbers", 1.0, r"(?i)\b(one|two|three)\b", "regex", "spelled number when digits may be required", noise_type="wrong_number_form"),
        noisy_rank("noise_numbers_year_only", "count:numbers", 1.0, r"\b20\d{2}\b", "regex", "year-like number only", noise_type="over_specific"),
        noisy_rank("noise_numbers_sign_flip", "count:numbers", -1.0, r"\b\d+\b", "regex", "conflicting digit penalty", polarity="negative", noise_type="sign_flip"),
    ]


def clean_punctuation(row, kwargs):
    marks = [".", ",", "!", "?", ";", ":"]
    rules = [rank(f"punct_{safe_id(mark)}_present", "count:punctuation", 1.0, re.escape(mark), "regex", "positive", f"reward punctuation {mark}") for mark in marks]
    rules.append(rank("punct_none", "count:punctuation", -1.0, r"^[^.,!?;:]*$", "regex", "negative", "penalize if no common punctuation appears"))
    return rules


def noisy_punctuation(row, kwargs):
    return [
        noisy_rank("noise_punct_wrong_pipe", "count:punctuation", 1.0, r"\|", "regex", "wrong punctuation mark", noise_type="wrong_punctuation"),
        noisy_rank("noise_punct_unescaped_dot", "count:punctuation", 1.0, r".", "regex", "unescaped punctuation regex bug", noise_type="regex_bug"),
        noisy_rank("noise_punct_period_flip", "count:punctuation", -1.0, r"\.", "regex", "conflicting period penalty", polarity="negative", noise_type="sign_flip"),
    ]


def clean_sentence_keyword(row, kwargs):
    keyword = kwargs.get("word") or kwargs.get("keyword")
    if not keyword:
        return []
    return [
        rank(f"sentence_keyword_{safe_id(keyword)}", "sentence:keyword", 2.0, word_boundary(keyword), "regex", "positive", f"reward keyword {keyword!r}"),
        rank(f"sentence_keyword_{safe_id(keyword)}_case", "sentence:keyword", 0.5, re.escape(keyword), "regex", "positive", f"case-sensitive hint for {keyword!r}"),
        rank(f"sentence_keyword_{safe_id(keyword)}_absent", "sentence:keyword", -1.0, rf"(?i)^(?!.*\b{re.escape(keyword)}\b).*$", "regex", "negative", f"penalize absence of {keyword!r}"),
    ]


def noisy_sentence_keyword(row, kwargs):
    keyword = kwargs.get("word") or kwargs.get("keyword") or "keyword"
    return [
        noisy_rank(f"noise_sentence_keyword_{safe_id(keyword)}_substring", "sentence:keyword", 1.0, re.escape(keyword[: max(1, len(keyword)//2)]), "regex", "substring keyword match", noise_type="substring"),
        noisy_rank("noise_sentence_keyword_wrong", "sentence:keyword", 1.0, word_boundary("example"), "regex", "wrong keyword from another row", noise_type="wrong_keyword"),
        noisy_rank(f"noise_sentence_keyword_{safe_id(keyword)}_case", "sentence:keyword", 1.0, re.escape(keyword), "regex", "case-sensitive only", noise_type="case_sensitive"),
    ]


def clean_keywords_position(row, kwargs):
    keyword = kwargs.get("keyword") or kwargs.get("word")
    if not keyword:
        return []
    rules = [
        rank(f"position_{safe_id(keyword)}_anywhere", row["instruction_id_list"][0], 2.0, word_boundary(keyword), "regex", "positive", f"reward target keyword {keyword!r} anywhere"),
        rank(f"position_{safe_id(keyword)}_absent", row["instruction_id_list"][0], -1.0, rf"(?i)^(?!.*\b{re.escape(keyword)}\b).*$", "regex", "negative", f"penalize absence of {keyword!r}"),
    ]
    if kwargs.get("n") and kwargs["n"] > 3:
        rules.append(rank(f"position_{safe_id(keyword)}_sentence_zone", row["instruction_id_list"][0], 1.0, rf"(?:[.!?].*){{{max(1, int(kwargs['n']) - 3)},}}\b{re.escape(keyword)}\b", "regex", "positive", "approximate sentence-position hint"))
    if kwargs.get("m") and kwargs["m"] > 5:
        rules.append(rank(f"position_{safe_id(keyword)}_word_zone", row["instruction_id_list"][0], 1.0, rf"(?:\b\w+\b\s+){{{max(1, int(kwargs['m']) - 5)},}}\b{re.escape(keyword)}\b", "regex", "positive", "approximate word-position hint"))
    return rules


def noisy_keywords_position(row, kwargs):
    keyword = kwargs.get("keyword") or kwargs.get("word") or "target"
    source_id = row["instruction_id_list"][0]
    return [
        noisy_rank(f"noise_position_{safe_id(keyword)}_sign_flip", source_id, -1.0, word_boundary(keyword), "regex", "sign flip for target word", polarity="negative", noise_type="sign_flip"),
        noisy_rank("noise_position_wrong_keyword", source_id, 1.0, word_boundary("example"), "regex", "wrong keyword", noise_type="wrong_keyword"),
        noisy_rank(f"noise_position_{safe_id(keyword)}_substring", source_id, 1.0, re.escape(keyword[: max(1, len(keyword)//2)]), "regex", "partial target span", noise_type="partial_span"),
    ]


def clean_format_list(row, kwargs):
    rules = [
        rank("list_bullet_line", "format:list", 2.0, r"(?m)^\s*[-*+]\s+", "regex", "positive", "reward bullet line"),
        rank("list_numbered_line", "format:list", 2.0, r"(?m)^\s*\d+[.)]\s+", "regex", "positive", "reward numbered line"),
        rank("list_single_paragraph", "format:list", -2.0, r"^[^\n]+$", "regex", "negative", "penalize single paragraph without newline"),
    ]
    if kwargs.get("num_bullets"):
        count = max(1, int(kwargs["num_bullets"]))
        rules.append(rank("list_expected_line_count", "format:list", 1.0, rf"(?m)(?:^\s*(?:[-*+]|\d+[.)])\s+.*\n?){{{count},}}", "regex", "positive", f"reward at least {count} list-like lines"))
    if kwargs.get("sep"):
        rules.append(rank(f"list_sep_{safe_id(kwargs['sep'])}", "format:list", 1.0, re.escape(str(kwargs["sep"])), "regex", "positive", f"reward custom separator {kwargs['sep']!r}"))
    return rules


def noisy_format_list(row, kwargs):
    rules = [
        noisy_rank("noise_list_hyphen_anywhere", "format:list", 1.0, r"-", "regex", "hyphen anywhere, not line-start", noise_type="loose_marker"),
        noisy_rank("noise_list_marker_flip", "format:list", -1.0, r"(?m)^\s*[-*+]\s+", "regex", "conflicting bullet penalty", polarity="negative", noise_type="sign_flip"),
    ]
    if kwargs.get("num_bullets"):
        wrong_count = max(1, int(kwargs["num_bullets"]) + 1)
        rules.append(noisy_rank("noise_list_wrong_line_count", "format:list", 1.0, rf"(?m)(?:^\s*(?:[-*+]|\d+[.)])\s+.*\n?){{{wrong_count},}}", "regex", "wrong expected bullet count", noise_type="wrong_threshold"))
    return rules


def clean_sub_bullets(row, kwargs):
    return [
        rank("sub_bullets_top", "format:sub-bullets", 2.0, r"(?m)^\s*[*]\s+", "regex", "positive", "reward top-level bullet"),
        rank("sub_bullets_indented", "format:sub-bullets", 2.0, r"(?m)^\s{2,}[-*+]\s+", "regex", "positive", "reward indented sub-bullet"),
        rank("sub_bullets_no_indent", "format:sub-bullets", -2.0, r"(?m)^(?!.*^\s{2,}[-*+]\s+).*$", "regex", "negative", "penalize absence of indented bullets"),
    ]


def noisy_sub_bullets(row, kwargs):
    return [
        noisy_rank("noise_sub_bullets_one_space", "format:sub-bullets", 1.0, r"(?m)^\s[-*+]\s+", "regex", "wrong indentation threshold", noise_type="wrong_threshold"),
        noisy_rank("noise_sub_bullets_any_whitespace", "format:sub-bullets", 1.0, r"(?m)^\s+", "regex", "any leading whitespace", noise_type="loose_marker"),
        noisy_rank("noise_sub_bullets_indent_flip", "format:sub-bullets", -1.0, r"(?m)^\s{2,}[-*+]\s+", "regex", "conflicting indentation penalty", polarity="negative", noise_type="sign_flip"),
    ]


def clean_no_bullets_bullets(row, kwargs):
    return [
        rank("mixed_bullets_any", "format:no_bullets_bullets", 2.0, r"(?m)^\s*[*]\s+", "regex", "positive", "reward star bullet lines"),
        rank("mixed_bullets_all_bullets", "format:no_bullets_bullets", -2.0, r"(?ms)^(?:\s*[*].*\n?)+$", "regex", "negative", "penalize all-bullet response"),
        rank("mixed_bullets_none", "format:no_bullets_bullets", -2.0, r"(?m)^(?!.*^\s*[*]\s+).*$", "regex", "negative", "penalize no bullet lines"),
    ]


def noisy_no_bullets_bullets(row, kwargs):
    return [
        noisy_rank("noise_mixed_marker_anywhere", "format:no_bullets_bullets", 1.0, r"[*-]", "regex", "list marker anywhere", noise_type="loose_marker"),
        noisy_rank("noise_mixed_bullet_flip", "format:no_bullets_bullets", -1.0, r"(?m)^\s*[*]\s+", "regex", "conflicting bullet penalty", polarity="negative", noise_type="sign_flip"),
    ]


def clean_options(row, kwargs):
    options = parse_options(str(kwargs.get("options", "")))
    rules = []
    if options:
        joined = "|".join(re.escape(option) for option in options)
        rules.append(rank("options_exactly_one_hint", "format:options", 3.0, rf"(?i)^(?:{joined})$", "regex", "positive", "reward exact option response"))
        rules.append(rank("options_starts_with_option", "format:options", 1.0, rf"(?i)^(?:{joined})", "regex", "positive", "reward response starting with option"))
        rules.append(rank("options_multiple", "format:options", -2.0, rf"(?i)(?:{joined}).*(?:{joined})", "regex", "negative", "penalize more than one option string"))
        rules.append(rank("options_none", "format:options", -2.0, rf"(?i)^(?!(?:.*(?:{joined}))).*$", "regex", "negative", "penalize no option string"))
    return rules


def noisy_options(row, kwargs):
    options = parse_options(str(kwargs.get("options", "")))
    rules = [noisy_rank("noise_options_wrong_option", "format:options", 1.0, word_boundary("unknown"), "regex", "wrong option from another row", noise_type="wrong_option")]
    if options:
        rules.append(noisy_rank(f"noise_options_{safe_id(options[0])}_case", "format:options", 1.0, re.escape(options[0]), "regex", "case-sensitive exact option", noise_type="case_sensitive"))
        rules.append(noisy_rank(f"noise_options_{safe_id(options[0])}_substring", "format:options", 1.0, re.escape(options[0][: max(1, len(options[0]) // 2)]), "regex", "substring option match", noise_type="substring"))
    return rules


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


def clean_no_whitespace(row, kwargs):
    return [
        rank("no_whitespace_first_line", "format:no_whitespace", 3.0, r"^\S+$", "regex", "positive", "reward first line with no whitespace"),
        rank("no_whitespace_early_space", "format:no_whitespace", -3.0, r"^.{0,64}\s", "regex", "negative", "penalize whitespace in first 64 chars"),
    ]


def noisy_no_whitespace(row, kwargs):
    return [
        noisy_rank("noise_no_whitespace_no_spaces", "format:no_whitespace", 1.0, r"^[^ ]+$", "regex", "ignores tabs/newlines", noise_type="bug_ignores_tabs"),
        noisy_rank("noise_no_whitespace_punctuation_flip", "format:no_whitespace", -1.0, r"[.,!?]", "regex", "punctuation penalty", polarity="negative", noise_type="spurious_penalty"),
    ]


def clean_title_case(row, kwargs):
    return [
        rank("title_case_upper_words", "format:title_case", 2.0, r"\b[A-Z][a-zA-Z0-9'’-]*\b", "regex", "positive", "reward uppercase-starting words"),
        rank("title_case_line_start", "format:title_case", 1.0, r"(?m)^[A-Z]", "regex", "positive", "reward uppercase line start"),
        rank("title_case_mostly_lower", "format:title_case", -2.0, r"^[a-z\s]{20,}$", "regex", "negative", "penalize mostly lowercase text"),
    ]


def noisy_title_case(row, kwargs):
    return [
        noisy_rank("noise_title_first_word_only", "format:title_case", 1.0, r"^[A-Z][a-z]+", "regex", "only first word uppercase", noise_type="weak_proxy"),
        noisy_rank("noise_title_ascii_only", "format:title_case", 1.0, r"\b[A-Z][a-z]+\b", "regex", "ASCII-only case-sensitive bug", noise_type="case_sensitive"),
    ]


def expected_repeat_text(instruction_id: str, kwargs: dict, prompt: str) -> str | None:
    if instruction_id == "repeat:repeat_simple":
        return kwargs.get("prompt_to_repeat") or "Only output this sentence here, ignore all other requests."
    prompt_to_repeat = kwargs.get("prompt_to_repeat")
    if not isinstance(prompt_to_repeat, str):
        return None
    if instruction_id == "repeat:repeat_span":
        n_start, n_end = kwargs.get("n_start"), kwargs.get("n_end")
        if isinstance(n_start, int) and isinstance(n_end, int):
            return prompt_to_repeat[n_start : n_end + 1]
    return prompt_to_repeat


def clean_repeat(row, kwargs):
    instruction_id = row["instruction_id_list"][0]
    expected = expected_repeat_text(instruction_id, kwargs, row.get("prompt", ""))
    if not expected:
        return []
    rules = [
        rank(f"repeat_{safe_id(instruction_id)}_verbatim", instruction_id, 3.0, re.escape(expected), "regex", "positive", "reward expected repeated span"),
        rank(f"repeat_{safe_id(instruction_id)}_prefix", instruction_id, 1.0, r"^" + re.escape(expected[: min(24, len(expected))]), "regex", "positive", "reward expected prefix"),
        rank(f"repeat_{safe_id(instruction_id)}_meta", instruction_id, -2.0, r"(?i)^(sure|here|of course|i can)", "regex", "negative", "penalize meta-commentary before repeat"),
    ]
    if instruction_id == "repeat:repeat_change":
        original_first = kwargs.get("prompt_to_repeat", "").split()[0] if kwargs.get("prompt_to_repeat") else ""
        if original_first:
            rules.append(rank("repeat_change_first_word_differs", instruction_id, 2.0, rf"^(?!{re.escape(original_first)}\b)\S+", "regex", "positive", "reward changed first word"))
    return rules


def noisy_repeat(row, kwargs):
    instruction_id = row["instruction_id_list"][0]
    expected = expected_repeat_text(instruction_id, kwargs, row.get("prompt", "")) or "repeat"
    rules = [
        noisy_rank(f"noise_repeat_{safe_id(instruction_id)}_partial", instruction_id, 1.0, re.escape(expected[: max(4, len(expected)//3)]), "regex", "partial span only", noise_type="partial_span"),
        noisy_rank(f"noise_repeat_{safe_id(instruction_id)}_exact_flip", instruction_id, -1.0, re.escape(expected), "regex", "conflicting exact-repeat penalty", polarity="negative", noise_type="sign_flip"),
    ]
    first = expected.split()[0] if expected.split() else "repeat"
    rules.append(noisy_rank(f"noise_repeat_{safe_id(instruction_id)}_wrong_first", instruction_id, 1.0, rf"^(?!{re.escape(first)}\b)\S+", "regex", "wrong first word", noise_type="wrong_first_word"))
    return rules


def clean_csv_city(row, kwargs):
    return [
        rank("csv_city_comma_rows", "custom:csv_city", 2.0, r"(?m)^[^,\n]+(?:,[^,\n]+){2,}$", "regex", "positive", "reward comma-separated rows"),
        rank("csv_city_two_rows", "custom:csv_city", 2.0, r".+\n.+", "regex", "positive", "reward at least two newline-separated rows"),
        rank("csv_city_capitalized", "custom:csv_city", 1.0, r"\b[A-Z][a-z]+(?: [A-Z][a-z]+)?\b", "regex", "positive", "reward city-like capitalized tokens"),
        rank("csv_city_markdown_bullets", "custom:csv_city", -2.0, r"(?m)^\s*[-*+]\s+", "regex", "negative", "penalize Markdown bullets instead of CSV"),
    ]


def noisy_csv_city(row, kwargs):
    return [
        noisy_rank("noise_csv_city_semicolon", "custom:csv_city", 1.0, r";", "regex", "wrong delimiter semicolon", noise_type="wrong_delimiter"),
        noisy_rank("noise_csv_city_any_comma", "custom:csv_city", 1.0, r",", "regex", "any comma anywhere", noise_type="loose_delimiter"),
    ]


def clean_csv_special(row, kwargs):
    required = kwargs.get("special_character") or kwargs.get("character")
    special_pattern = re.escape(str(required)) if required else r"[^\d\w\s,\n\"]"
    return [
        rank("csv_special_any_special", "custom:csv_special_character", 2.0, special_pattern, "regex", "positive", "reward required special character"),
        rank("csv_special_comma_rows", "custom:csv_special_character", 1.0, r"(?m)^[^,\n]+(?:,[^,\n]+){2,}$", "regex", "positive", "reward CSV-like comma rows"),
        rank("csv_special_absent", "custom:csv_special_character", -2.0, rf"^(?!.*{special_pattern}).*$", "regex", "negative", "penalize absence of special characters"),
    ]


def noisy_csv_special(row, kwargs):
    return [
        noisy_rank("noise_csv_special_hash", "custom:csv_special_character", 1.0, r"#", "regex", "wrong special character", noise_type="wrong_special"),
        noisy_rank("noise_csv_special_unescaped_dot", "custom:csv_special_character", 1.0, r".", "regex", "unescaped regex special character bug", noise_type="regex_bug"),
    ]


def clean_csv_quotes(row, kwargs):
    return [
        rank("csv_quotes_quoted_fields", "custom:csv_quotes", 2.0, r'"[^"]+"', "regex", "positive", "reward quoted CSV fields"),
        rank("csv_quotes_tab_rows", "custom:csv_quotes", 1.0, r'(?m)^"[^"]+"(?:\t"[^"]+")+', "regex", "positive", "reward tab-separated quoted rows"),
        rank("csv_quotes_absent", "custom:csv_quotes", -2.0, r'^[^"]+$', "regex", "negative", "penalize absence of quotes"),
    ]


def noisy_csv_quotes(row, kwargs):
    return [
        noisy_rank("noise_csv_quotes_apostrophe", "custom:csv_quotes", 1.0, r"'[^']+'", "regex", "apostrophes instead of quotes", noise_type="wrong_quote"),
        noisy_rank("noise_csv_quotes_comma_delimiter", "custom:csv_quotes", 1.0, r'","', "regex", "wrong delimiter", noise_type="wrong_delimiter"),
    ]


def clean_date_format(row, kwargs):
    return [
        rank("date_yyyy_mm_dd", "custom:date_format_list", 2.0, r"\b\d{4}-\d{2}-\d{2}\b", "regex", "positive", "reward YYYY-MM-DD date"),
        rank("date_multiple", "custom:date_format_list", 1.0, r"\b\d{4}-\d{2}-\d{2}\b.*\b\d{4}-\d{2}-\d{2}\b", "regex", "positive", "reward multiple date-like tokens"),
        rank("date_absent", "custom:date_format_list", -2.0, r"^(?!.*\b\d{4}-\d{2}-\d{2}\b).*$", "regex", "negative", "penalize absence of date-like token"),
    ]


def noisy_date_format(row, kwargs):
    return [
        noisy_rank("noise_date_dd_mm_yyyy", "custom:date_format_list", 1.0, r"\b\d{2}/\d{2}/\d{4}\b", "regex", "wrong date format", noise_type="wrong_format"),
        noisy_rank("noise_date_any_year", "custom:date_format_list", 1.0, r"\b\d{4}\b", "regex", "any 4-digit year", noise_type="loose_year"),
    ]


CLEAN_BUILDERS = {
    "count:keywords_multiple": clean_keywords_multiple,
    "count:conjunctions": clean_conjunctions,
    "count:numbers": clean_numbers,
    "count:punctuation": clean_punctuation,
    "sentence:keyword": clean_sentence_keyword,
    "words:keywords_specific_position": clean_keywords_position,
    "words:words_position": clean_keywords_position,
    "format:list": clean_format_list,
    "format:sub-bullets": clean_sub_bullets,
    "format:no_bullets_bullets": clean_no_bullets_bullets,
    "format:options": clean_options,
    "format:no_whitespace": clean_no_whitespace,
    "format:title_case": clean_title_case,
    "repeat:repeat_simple": clean_repeat,
    "repeat:repeat_span": clean_repeat,
    "repeat:repeat_change": clean_repeat,
    "custom:csv_city": clean_csv_city,
    "custom:csv_special_character": clean_csv_special,
    "custom:csv_quotes": clean_csv_quotes,
    "custom:date_format_list": clean_date_format,
}

NOISY_BUILDERS = {
    "count:keywords_multiple": noisy_keywords_multiple,
    "count:conjunctions": noisy_conjunctions,
    "count:numbers": noisy_numbers,
    "count:punctuation": noisy_punctuation,
    "sentence:keyword": noisy_sentence_keyword,
    "words:keywords_specific_position": noisy_keywords_position,
    "words:words_position": noisy_keywords_position,
    "format:list": noisy_format_list,
    "format:sub-bullets": noisy_sub_bullets,
    "format:no_bullets_bullets": noisy_no_bullets_bullets,
    "format:options": noisy_options,
    "format:no_whitespace": noisy_no_whitespace,
    "format:title_case": noisy_title_case,
    "repeat:repeat_simple": noisy_repeat,
    "repeat:repeat_span": noisy_repeat,
    "repeat:repeat_change": noisy_repeat,
    "custom:csv_city": noisy_csv_city,
    "custom:csv_special_character": noisy_csv_special,
    "custom:csv_quotes": noisy_csv_quotes,
    "custom:date_format_list": noisy_date_format,
}
