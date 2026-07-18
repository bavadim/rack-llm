from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

SOFT_FAMILIES = [
    "count:conjunctions", "count:numbers", "count:word_count_range",
    "format:list", "format:sub-bullets", "format:newline",
    "format:no_bullets_bullets", "format:emoji", "format:thesis",
    "format:quotes", "format:parentheses", "sentence:keyword",
]
ALL_KWARGS = [
    "N", "capital_frequency", "capital_relation", "end_phrase", "first_word",
    "forbidden_words", "frequency", "keyword", "keyword1", "keyword2",
    "keyword3", "keyword4", "keyword5", "keywords", "language",
    "let_frequency", "let_relation", "letter", "m", "max_words", "min_words",
    "n", "n_end", "n_start", "nth_paragraph", "num_bullets",
    "num_highlights", "num_paragraphs", "num_placeholders", "num_sections",
    "num_sentences", "num_words", "options", "percentage",
    "postscript_marker", "prompt_to_repeat", "reference_text", "relation",
    "section_spliter", "sep", "small_n", "word",
]
ANY = "(.|\\n)"
DATA = Path(__file__).resolve().parents[3] / "data" / "pwseq-ifbench"
RULE_NAMESPACE = uuid.uuid5(
    uuid.NAMESPACE_URL,
    "https://github.com/bavadim/rack-llm/pwseq-ifbench/rules/v4",
)


@dataclass(frozen=True)
class BuiltSpec:
    hard_spec: dict[str, Any]
    weak_rules: list[dict[str, Any]]


def empty_kwargs(**updates: Any) -> dict[str, Any]:
    result = {key: None for key in ALL_KWARGS}
    result.update(updates)
    return result


def escape(text: str) -> str:
    return re.sub(r"([.\\+*?\[\](){}|^$])", r"\\\1", text)


def rule_id(family: str, source_slot: int) -> str:
    return str(uuid.uuid5(RULE_NAMESPACE, f"{family}:{source_slot}"))


@lru_cache(maxsize=1)
def _rule_templates() -> dict[str, tuple[dict[str, Any], ...]]:
    by_family: dict[str, list[dict[str, Any]]] = {family: [] for family in SOFT_FAMILIES}
    for name, author, slots in [
        ("author_a.json", "A", range(0, 5)),
        ("author_b.json", "B", range(5, 10)),
    ]:
        packet = json.loads((DATA / name).read_text(encoding="utf-8"))
        if packet.get("author") != author or packet.get("protocol") != "verifier-blind-v1":
            raise RuntimeError(f"invalid frozen author packet: {name}")
        if set(packet.get("families", {})) != set(SOFT_FAMILIES):
            raise RuntimeError(f"family mismatch in frozen author packet: {name}")
        for family in SOFT_FAMILIES:
            rules = packet["families"][family]
            if [rule["slot"] for rule in rules] != list(slots):
                raise RuntimeError(f"slot mismatch in {name}/{family}")
            by_family[family].extend(rules)
    output = {}
    for family, rules in by_family.items():
        polarities = [rule["polarity"] for rule in rules]
        if len(rules) != 10 or polarities.count("positive") != 6 or polarities.count("negative") != 4:
            raise RuntimeError(f"invalid two-author inventory: {family}")
        output[family] = tuple(rules)
    return output


def _integer(kwargs: dict[str, Any], name: str) -> int:
    value = kwargs.get(name)
    if value is None or int(value) != float(value):
        raise ValueError(f"{name} must be an integer")
    return int(value)


def _render(template: str, placeholders: list[str], kwargs: dict[str, Any]) -> str:
    output = template
    numeric = {
        name: _integer(kwargs, name)
        for name in placeholders if name in {"N", "small_n", "min_words", "max_words"}
    }
    # Author B uses doubled braces to explicitly mark a rendered quantifier.
    if "min_words" in numeric and "max_words" in numeric:
        output = output.replace(
            "{{min_words},{max_words}}",
            f"{{{numeric['min_words']},{numeric['max_words']}}}",
        )
    if "max_words" in numeric:
        output = output.replace("{{max_words},}", f"{{{numeric['max_words']},}}")
    for name, value in numeric.items():
        output = output.replace("{{" + name + "}}", f"{{{value}}}")
        # A single placeholder is always a literal value. Quantifiers use the
        # explicit doubled-brace authoring form above; no context heuristic is
        # allowed because `(^|\n){N}` can mean a numeric sentence label.
        output = output.replace("{" + name + "}", str(value))
    for name in placeholders:
        if name in numeric:
            continue
        value = kwargs.get(name)
        if value is None:
            raise ValueError(f"{name} is required")
        output = output.replace("{" + name + "}", escape(str(value)))
    if re.search(r"\{[A-Za-z_][A-Za-z0-9_]*\}", output):
        raise RuntimeError(f"unrendered weak-rule placeholder: {output}")
    return output


def build(family: str, kwargs: dict[str, Any], max_tokens: int) -> BuiltSpec:
    if family not in SOFT_FAMILIES:
        raise KeyError(family)
    rules = []
    for template in _rule_templates()[family]:
        slot = int(template["slot"])
        rules.append({
            "slot": slot,
            "source_slot": slot,
            "rule_id": rule_id(family, slot),
            "polarity": template["polarity"],
            "pattern": _render(
                template["pattern_template"],
                list(template.get("placeholders", [])),
                kwargs,
            ),
        })
    return BuiltSpec(
        hard_spec={"kind": "text", "max_tokens": int(max_tokens)},
        weak_rules=rules,
    )


MIXED_FAMILIES = ["format:list", "format:newline", "format:quotes", "format:parentheses"]


def build_mixed(family: str, kwargs: dict[str, Any], max_tokens: int) -> BuiltSpec:
    base = build(family, kwargs, max_tokens)
    if family == "format:list":
        marker = "([-*+]|[0-9]+[.)]|" + escape(str(kwargs["sep"])) + ")"
        line = f"[ \\t]*{marker}[ \\t]+[^\\n]+"
        pattern = f"^{line}(\\n{line}){{1,}}$"
    elif family == "format:newline":
        pattern = "^[^\\n]+(\\n[^\\n]+){3,}$"
    elif family == "format:quotes":
        pattern = f"^{ANY}*\"{ANY}*'{ANY}*$|^{ANY}*'{ANY}*\"{ANY}*$"
    elif family == "format:parentheses":
        # A deliberately coarse three-level envelope.  The weak rules remain
        # responsible for depth five, alternative orders, and mismatch cues.
        pattern = (
            "^" + ANY + "*[(]" + ANY + "*\\[" + ANY + "*\\{" +
            ANY + "*\\}" + ANY + "*\\]" + ANY + "*[)]" + ANY + "*$"
        )
    else:
        raise KeyError(family)
    return BuiltSpec(
        hard_spec={"kind": "ere", "pattern": pattern, "max_tokens": int(max_tokens)},
        weak_rules=base.weak_rules,
    )
