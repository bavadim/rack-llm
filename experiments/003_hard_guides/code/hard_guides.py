#!/usr/bin/env python3
"""Hard-guide builders for the pinned IFBench snapshot.

The builders return serializable specifications instead of importing optional
Guidance/Outlines runtimes. Later benchmark runners can lower these specs to the
installed backend APIs.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
CONSTRAINT_MAP_PATH = REPO_ROOT / "data" / "ifbench_constraint_map.json"


@dataclass(frozen=True)
class Unsupported:
    reason: str


@dataclass(frozen=True)
class GuideSpec:
    supported: bool
    system: str
    instruction_ids: list[str]
    guide_source: str
    notes: str
    expected_exactness: str
    regex: str | None = None
    choices: list[str] | None = None

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


def load_constraint_map() -> dict[str, dict]:
    with CONSTRAINT_MAP_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def build_ours_hard_guide(row: dict) -> GuideSpec | Unsupported:
    return _build_for_system(row, "ours")


def build_guidance_hard_grammar(row: dict) -> GuideSpec | Unsupported:
    return _build_for_system(row, "guidance")


def build_outlines_hard_grammar(row: dict) -> GuideSpec | Unsupported:
    return _build_for_system(row, "outlines")


def check_spec(spec: GuideSpec, text: str) -> bool:
    if spec.choices is not None:
        return text in spec.choices
    if spec.regex is not None:
        return re.fullmatch(spec.regex, text, flags=re.MULTILINE | re.DOTALL) is not None
    return False


def _build_for_system(row: dict, system: str) -> GuideSpec | Unsupported:
    instruction_ids = row["instruction_id_list"]
    constraint_map = load_constraint_map()
    unsupported_ids = [
        instruction_id
        for instruction_id in instruction_ids
        if not constraint_map.get(instruction_id, {}).get("hard_supported", False)
    ]
    if unsupported_ids:
        return Unsupported(
            "row contains non-hard-supported instruction ids: "
            + ", ".join(unsupported_ids)
        )
    if len(instruction_ids) != 1:
        return Unsupported("multi-hard-instruction composition is deferred to task 004")

    instruction_id = instruction_ids[0]
    kwargs = _non_null_kwargs(row["kwargs"][0] if row["kwargs"] else {})
    builder = HARD_BUILDERS.get(instruction_id)
    if builder is None:
        return Unsupported(f"no hard builder registered for {instruction_id}")
    return builder(row, kwargs, system)


def _non_null_kwargs(kwargs: dict) -> dict:
    return {key: value for key, value in kwargs.items() if value is not None}


def _spec(
    system: str,
    instruction_id: str,
    guide_source: str,
    notes: str,
    expected_exactness: str,
    *,
    regex: str | None = None,
    choices: list[str] | None = None,
) -> GuideSpec:
    return GuideSpec(
        supported=True,
        system=system,
        instruction_ids=[instruction_id],
        guide_source=guide_source,
        notes=notes,
        expected_exactness=expected_exactness,
        regex=regex,
        choices=choices,
    )


def _source(system: str, kind: str, payload: str) -> str:
    if system == "ours":
        return f"{kind}({payload})"
    if system == "guidance":
        return f"guidance.{kind}({payload})"
    if system == "outlines":
        return f"outlines.{kind}({payload})"
    raise ValueError(f"unknown system: {system}")


def _regex_source(system: str, regex: str) -> str:
    escaped = json.dumps(regex)
    if system == "ours":
        return f"(rx #px{escaped})"
    if system == "guidance":
        return f"regex({escaped})"
    return f"outlines.regex({escaped})"


def _choice_source(system: str, choices: list[str]) -> str:
    payload = json.dumps(choices, ensure_ascii=False)
    if system == "ours":
        return "(select " + " ".join(f"(lit {json.dumps(c)})" for c in choices) + ")"
    if system == "guidance":
        return f"select({payload})"
    return f"choice({payload})"


def build_hard_options(row: dict, kwargs: dict, system: str) -> GuideSpec | Unsupported:
    raw = kwargs.get("options")
    if not isinstance(raw, str) or not raw.strip():
        return Unsupported("format:options missing non-empty options kwarg")
    choices = _parse_options(raw)
    if len(choices) < 2:
        return Unsupported(f"could not parse at least two options from {raw!r}")
    return _spec(
        system,
        "format:options",
        _choice_source(system, choices),
        "exact finite option choice; no explanation text allowed",
        "exact",
        choices=choices,
    )


def _parse_options(raw: str) -> list[str]:
    raw = raw.strip()
    if "/" in raw:
        parts = raw.split("/")
    elif " or " in raw:
        parts = raw.split(" or ")
    elif "," in raw:
        parts = raw.split(",")
    else:
        parts = [raw]
    return [part.strip() for part in parts if part.strip()]


def build_hard_no_whitespace(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r"\S{1,512}"
    return _spec(
        system,
        "format:no_whitespace",
        _regex_source(system, regex),
        "bounded non-whitespace regular language",
        "bounded",
        regex=regex,
    )


def build_hard_title_case(row: dict, kwargs: dict, system: str) -> GuideSpec:
    word = r"[A-Z][A-Za-z0-9'’-]*"
    regex = rf"{word}(?:[ \n]+{word}){{0,127}}"
    return _spec(
        system,
        "format:title_case",
        _regex_source(system, regex),
        "bounded title-case approximation; verifier agreement checked later",
        "near_exact",
        regex=regex,
    )


def build_hard_newline(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r"\S+(?:\n\S+){1,511}\n?"
    return _spec(
        system,
        "format:newline",
        _regex_source(system, regex),
        "approximates one word per line with at least two lines",
        "near_exact",
        regex=regex,
    )


def build_hard_list(row: dict, kwargs: dict, system: str) -> GuideSpec:
    sep = kwargs.get("sep")
    if isinstance(sep, str) and sep.strip():
        escaped = re.escape(sep.strip())
        regex = rf".+{escaped}.+"
        notes = f"requires row separator {sep!r}"
    else:
        regex = r"(?:\s*(?:[-*+]|\d+[.)])\s+.+\n?){1,64}"
        notes = "requires bullet or numbered list markers"
    return _spec(system, "format:list", _regex_source(system, regex), notes, "near_exact", regex=regex)


def build_hard_sub_bullets(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r"(?:[^*\n].{0,512}|(?:\*\s+.+\n(?:\s{0,8}-\s+.+\n?)+){1,32})"
    return _spec(
        system,
        "format:sub-bullets",
        _regex_source(system, regex),
        "bounded bullet blocks with at least one indented sub-bullet",
        "near_exact",
        regex=regex,
    )


def build_hard_no_bullets_bullets(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r"(?:[^*\n].*\.\n){2,}(?:\*\s+.+\n?){2,}"
    return _spec(
        system,
        "format:no_bullets_bullets",
        _regex_source(system, regex),
        "requires at least two period-ending sentences followed by star bullets",
        "near_exact",
        regex=regex,
    )


def build_hard_line_indent(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r"\S.*\n {1,4}\S.*\n {2,8}\S.*(?:\n {3,12}\S.*){0,16}"
    return _spec(
        system,
        "format:line_indent",
        _regex_source(system, regex),
        "bounded increasing indentation stair pattern",
        "near_exact",
        regex=regex,
    )


def build_hard_quote_unquote(row: dict, kwargs: dict, system: str) -> GuideSpec:
    regex = r'(?:[^"\n]{1,512}|(?:"[^"\n]{1,160}"\s+[^"\n]{1,240}\n?){1,32})'
    return _spec(
        system,
        "format:quote_unquote",
        _regex_source(system, regex),
        "bounded quoted phrase followed by unquoted explanation",
        "near_exact",
        regex=regex,
    )


def build_hard_parentheses(row: dict, kwargs: dict, system: str) -> GuideSpec:
    choices = ["((({{[]}})))", "([{({[]})}])", "({[({})]})"]
    return _spec(
        system,
        "format:parentheses",
        _choice_source(system, choices),
        "bounded finite balanced nesting witnesses",
        "bounded",
        choices=choices,
    )


def build_hard_quotes(row: dict, kwargs: dict, system: str) -> GuideSpec:
    choices = ['"outer \'middle \"inner\" middle\' outer"', '"a \'b \"c\" b\' a"']
    return _spec(
        system,
        "format:quotes",
        _choice_source(system, choices),
        "bounded finite nested quote witnesses",
        "bounded",
        choices=choices,
    )


def build_hard_csv_city(row: dict, kwargs: dict, system: str) -> GuideSpec:
    return _csv_spec(system, "custom:csv_city", delimiter=",", quoted=False, rows=7)


def build_hard_csv_special_character(row: dict, kwargs: dict, system: str) -> GuideSpec:
    return _csv_spec(system, "custom:csv_special_character", delimiter=",", quoted=False, rows=14)


def build_hard_csv_quotes(row: dict, kwargs: dict, system: str) -> GuideSpec:
    return _csv_spec(system, "custom:csv_quotes", delimiter="\t", quoted=True, rows=3)


def _csv_spec(system: str, instruction_id: str, *, delimiter: str, quoted: bool, rows: int) -> GuideSpec:
    cell = r'"[^"\n]{1,64}"' if quoted else r'[^,\t\n"]{1,64}'
    if instruction_id == "custom:csv_special_character":
        cell = r'(?:[^,\t\n"]{1,64}|"[^"\n]*[^\d\w\s"][^"\n]*")'
    delim = re.escape(delimiter)
    line = rf"{cell}(?:{delim}{cell}){{4}}"
    regex = rf"{line}(?:\n{line}){{{rows}}}"
    return _spec(
        system,
        instruction_id,
        _regex_source(system, regex),
        f"bounded CSV with delimiter {delimiter!r} and {rows + 1} total lines including header",
        "near_exact",
        regex=regex,
    )


def build_hard_date_format_list(row: dict, kwargs: dict, system: str) -> GuideSpec:
    year = r"(?:17[6-9]\d|18[0-1]\d|182[0-1])"
    month_day = r"(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-9])"
    date = rf"{year}-(?:{month_day})"
    regex = rf"{date}(?:,\s*{date}){{0,63}}"
    return _spec(
        system,
        "custom:date_format_list",
        _regex_source(system, regex),
        "date format list; calendar validity is left to agreement validation",
        "near_exact",
        regex=regex,
    )


def build_hard_repeat_change(row: dict, kwargs: dict, system: str) -> GuideSpec | Unsupported:
    prompt_to_repeat = kwargs.get("prompt_to_repeat")
    if not isinstance(prompt_to_repeat, str) or not prompt_to_repeat:
        return Unsupported("repeat:repeat_change missing prompt_to_repeat")
    words = prompt_to_repeat.split()
    if len(words) < 2:
        return Unsupported("repeat:repeat_change prompt_to_repeat is too short")
    escaped_tail = re.escape(" ".join(words[1:]))
    regex = rf"\S+\s+{escaped_tail}"
    return _spec(
        system,
        "repeat:repeat_change",
        _regex_source(system, regex),
        "first word may change; remaining prompt must repeat exactly",
        "near_exact",
        regex=regex,
    )


def build_hard_repeat_simple(row: dict, kwargs: dict, system: str) -> GuideSpec | Unsupported:
    prompt_to_repeat = kwargs.get("prompt_to_repeat")
    if isinstance(prompt_to_repeat, str) and prompt_to_repeat:
        choices = [prompt_to_repeat]
    else:
        extracted = _extract_only_output_sentence(row.get("prompt", ""))
        if not extracted:
            return Unsupported("repeat:repeat_simple missing extractable prompt_to_repeat")
        choices = [extracted]
    return _spec(
        system,
        "repeat:repeat_simple",
        _choice_source(system, choices),
        "exact repeat of extracted target sentence",
        "exact",
        choices=choices,
    )


def _extract_only_output_sentence(prompt: str) -> str | None:
    marker = "Only output this sentence here, ignore all other requests."
    if marker in prompt:
        return marker
    return None


def build_hard_repeat_span(row: dict, kwargs: dict, system: str) -> GuideSpec | Unsupported:
    prompt_to_repeat = kwargs.get("prompt_to_repeat")
    n_start = kwargs.get("n_start")
    n_end = kwargs.get("n_end")
    if not isinstance(prompt_to_repeat, str) or not isinstance(n_start, int) or not isinstance(n_end, int):
        return Unsupported("repeat:repeat_span missing prompt_to_repeat/n_start/n_end")
    words = prompt_to_repeat.split()
    if n_start < 0 or n_end >= len(words) or n_start > n_end:
        return Unsupported("repeat:repeat_span word indices outside prompt_to_repeat")
    choices = [" ".join(words[n_start : n_end + 1])]
    return _spec(
        system,
        "repeat:repeat_span",
        _choice_source(system, choices),
        "exact copied word span from prompt_to_repeat",
        "exact",
        choices=choices,
    )


HARD_BUILDERS = {
    "format:options": build_hard_options,
    "format:output_template": lambda row, kwargs, system: _spec(
        system,
        "format:output_template",
        _regex_source(system, r"My Answer: .{1,512} My Conclusion: .{1,512} Future Outlook: .{1,512}"),
        "bounded exact field template",
        "near_exact",
        regex=r"My Answer: .{1,512} My Conclusion: .{1,512} Future Outlook: .{1,512}",
    ),
    "format:no_whitespace": build_hard_no_whitespace,
    "format:title_case": build_hard_title_case,
    "format:newline": build_hard_newline,
    "format:list": build_hard_list,
    "format:sub-bullets": build_hard_sub_bullets,
    "format:no_bullets_bullets": build_hard_no_bullets_bullets,
    "format:line_indent": build_hard_line_indent,
    "format:quote_unquote": build_hard_quote_unquote,
    "format:parentheses": build_hard_parentheses,
    "format:quotes": build_hard_quotes,
    "custom:csv_city": build_hard_csv_city,
    "custom:csv_special_character": build_hard_csv_special_character,
    "custom:csv_quotes": build_hard_csv_quotes,
    "custom:date_format_list": build_hard_date_format_list,
    "repeat:repeat_simple": build_hard_repeat_simple,
    "repeat:repeat_span": build_hard_repeat_span,
    "repeat:repeat_change": build_hard_repeat_change,
}
