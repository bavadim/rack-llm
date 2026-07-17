from __future__ import annotations

import math
import re
import uuid
from dataclasses import dataclass
from typing import Any, Callable

SOFT_FAMILIES = [
    "count:keywords_multiple", "count:conjunctions", "count:numbers",
    "count:word_count_range", "format:list", "format:sub-bullets",
    "format:newline", "format:no_bullets_bullets", "format:emoji",
    "format:thesis", "format:quotes", "format:line_indent",
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
WORD = "[A-Za-z0-9_]+"
NONWORD = "[^A-Za-z0-9_]"
EMOJIS = ["😀", "🙂", "✅", "🔍", "📌", "🧭", "⚙️", "🧪", "🌱", "📚", "💡", "🛠️"]
EMOJI_ALT = "(" + "|".join(EMOJIS) + ")"


@dataclass(frozen=True)
class BuiltSpec:
    hard_spec: dict[str, Any]
    weak_rules: list[dict[str, Any]]


RULE_NAMESPACE = uuid.uuid5(
    uuid.NAMESPACE_URL,
    "https://github.com/bavadim/rack-llm/pwseq-ifbench/rules",
)


def rule_id(family: str, source_slot: int) -> str:
    return str(uuid.uuid5(RULE_NAMESPACE, f"{family}:{source_slot}"))


def empty_kwargs(**updates: Any) -> dict[str, Any]:
    out = {key: None for key in ALL_KWARGS}
    out.update(updates)
    return out


def escape(text: str) -> str:
    return re.sub(r"([.\\+*?\[\](){}|^$])", r"\\\1", text)


def ci(text: str) -> str:
    return "".join(f"[{c.lower()}{c.upper()}]" if c.isascii() and c.isalpha() else escape(c) for c in text)


def word(text: str) -> str:
    return f"(^|{NONWORD}){ci(text)}({NONWORD}|$)"


def occurrences(pattern: str, count: int) -> str:
    return "^" + ANY + "*" + (ANY + "*" + pattern) * count + ANY + "*$"


def line_marker(marker: str) -> str:
    return f"(^|\\n)[ \\t]*{escape(marker)}[ \\t]+"


def word_between(lo: int, hi: int | None = None) -> str:
    quant = f"{{{lo},}}" if hi is None else f"{{{lo},{hi}}}"
    return f"^[^A-Za-z0-9_]*({WORD}[^A-Za-z0-9_]*){quant}$"


def rule(slot: int, polarity: str, pattern: str) -> dict[str, Any]:
    return {"slot": slot, "polarity": polarity, "pattern": pattern}


def refusal(slot: int) -> dict[str, Any]:
    return rule(slot, "negative", "(I cannot|I can not|I am unable|unable to comply|cannot comply|I will not)")


def rules_keywords(k: dict[str, Any]) -> list[dict[str, Any]]:
    w = [k[f"keyword{i}"] for i in range(1, 6)]
    return [
        rule(0, "positive", word(w[0])),
        rule(1, "positive", occurrences(word(w[1]), 2)),
        rule(2, "positive", occurrences(word(w[3]), 2)),
        rule(3, "positive", occurrences(word(w[4]), 3)),
        rule(4, "negative", "(include keyword|keyword .* times|in your response)"),
        refusal(5),
    ]


def rules_conjunctions(_: dict[str, Any]) -> list[dict[str, Any]]:
    a, b = word("and"), word("but")
    return [
        rule(0, "positive", a), rule(1, "positive", b),
        rule(2, "positive", f"({word('or')}|{word('yet')}|{word('nor')})"),
        rule(3, "positive", f"^({ANY})*{a}({ANY})*{b}({ANY})*$|^({ANY})*{b}({ANY})*{a}({ANY})*$"),
        rule(4, "negative", occurrences(a, 5)),
        rule(5, "negative", "coordinating conjunction"), refusal(6),
    ]


def number_token() -> str:
    return "(^|[^0-9])[0-9]+([^0-9]|$)"


def rules_numbers(k: dict[str, Any]) -> list[dict[str, Any]]:
    n = int(k["N"])
    token = number_token()
    return [
        rule(0, "positive", token),
        rule(1, "positive", occurrences(token, max(1, n // 2))),
        rule(2, "positive", occurrences(token, n)),
        rule(3, "negative", occurrences(token, n + 2)),
        rule(4, "negative", "(^|[^A-Za-z_])(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen)([^A-Za-z_]|$)"),
        refusal(5),
    ]


def rules_word_range(k: dict[str, Any]) -> list[dict[str, Any]]:
    lo, hi = int(k["min_words"]), int(k["max_words"])
    return [
        rule(0, "positive", word_between(max(1, math.floor(lo * .75)), math.ceil(hi * 1.25))),
        rule(1, "positive", word_between(max(1, math.floor(lo * .9)))),
        rule(2, "positive", word_between(1, math.ceil(hi * 1.1))),
        rule(3, "negative", word_between(1, max(1, math.floor(lo * .5)))),
        rule(4, "negative", word_between(math.ceil(hi * 1.5))),
        refusal(5),
    ]


def rules_list(k: dict[str, Any]) -> list[dict[str, Any]]:
    p = line_marker(str(k["sep"]))
    return [
        rule(0, "positive", p),
        rule(1, "positive", f"^{ANY}*{p}{ANY}*{p}{ANY}*$"),
        rule(2, "positive", f"^{ANY}*{p}{ANY}*{p}{ANY}*{p}{ANY}*$"),
        rule(3, "negative", "(^|\\n)[ \\t]*[-*+][ \\t]+" if k["sep"] not in {"-", "*", "+"} else "(^|\\n)[ \\t]*[A-Za-z][.)][ \\t]+"),
        rule(4, "negative", "(^|\\n)[ \\t]*[0-9]+[.)][ \\t]+"),
        rule(5, "negative", "^[^\\n]{240,}$"),
    ]


def rules_subbullets(_: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        rule(0, "positive", "(^|\\n)[ \\t]*\\*[ \\t]+"),
        rule(1, "positive", "(^|\\n)[ \\t]+-[ \\t]+"),
        rule(2, "positive", f"^{ANY}*(^|\\n)[ \\t]*\\*[ \\t]+{ANY}*(^|\\n)[ \\t]+-[ \\t]+{ANY}*$"),
        rule(3, "negative", "(^|\\n)-[ \\t]+"),
        rule(4, "negative", "(^|\\n)[ \\t]*[0-9]+[.)][ \\t]+"),
        rule(5, "negative", "^[^\\n]{240,}$"),
    ]


def rules_newline(_: dict[str, Any]) -> list[dict[str, Any]]:
    one = "[^ \\t\\r\\n]+"
    return [
        rule(0, "positive", f"^{one}(\\n{one}){{4,}}$"),
        rule(1, "positive", f"^{one}(\\n{one}){{9,}}$"),
        rule(2, "positive", f"^{one}\\n{one}\\n{one}\\n{one}({ANY})*$"),
        rule(3, "negative", "(^|\\n)[^\\n]*[ \\t]+[^\\n]*"),
        rule(4, "negative", "\\n\\n"), rule(5, "negative", "^[^\\n]{100,}$"),
    ]


def rules_prose_bullets(_: dict[str, Any]) -> list[dict[str, Any]]:
    star = "(^|\\n)[ \\t]*\\*[ \\t]+"
    return [
        rule(0, "positive", f"^{ANY}*\\.{ANY}*\\.{ANY}*{star}{ANY}*$"),
        rule(1, "positive", f"^{ANY}*{star}{ANY}*{star}{ANY}*$"),
        rule(2, "positive", f"^[^*]+{star}{ANY}*$"),
        rule(3, "negative", "^[ \\t]*\\*[ \\t]+"),
        rule(4, "negative", "(^|\\n)[ \\t]*-[ \\t]+"),
        rule(5, "negative", "^[^\\n]{260,}$"),
    ]


def rules_emoji(_: dict[str, Any]) -> list[dict[str, Any]]:
    symbols = "".join(EMOJIS)
    return [
        rule(0, "positive", EMOJI_ALT),
        rule(1, "positive", f"^{ANY}*{EMOJI_ALT}{ANY}*{EMOJI_ALT}{ANY}*$"),
        rule(2, "positive", f"[.!?][ \\t]*{EMOJI_ALT}"),
        rule(3, "negative", f"(^|\\n)[^{symbols}\\n]*[.!?][ \\t]*($|\\n)"),
        rule(4, "negative", "(^|\\n)[^\\n]*[.!?][ \\t]*[A-Za-z0-9]"),
        rule(5, "negative", "(:-?\\)|:-?\\(|;[-]?\\)|:smile:|:emoji:|emoji here)"),
    ]


def rules_thesis(_: dict[str, Any]) -> list[dict[str, Any]]:
    ital = "(^|\\n)[ \\t]*<i>[^<]+</i>"
    return [
        rule(0, "positive", ital),
        rule(1, "positive", f"^{ANY}*{ital}{ANY}*{ital}{ANY}*$"),
        rule(2, "positive", "<i>[^<]+[.!?:]</i>"),
        rule(3, "negative", "(^|\\n)[ \\t]*\\*[^*]+\\*"),
        rule(4, "negative", "(^|\\n)[ \\t]*<em>"),
        rule(5, "negative", "(^|\\n)[ \\t]*_[^_]+_"),
    ]


def rules_quotes(_: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        rule(0, "positive", '"' + ANY + "*'"),
        rule(1, "positive", '"' + ANY + "*'" + ANY + '*"'),
        rule(2, "positive", "'" + ANY + '*"' + ANY + "*'"),
        rule(3, "negative", '"[^\"\n]*"'),
        rule(4, "negative", "'[^'\n]*'"), refusal(5),
    ]


def rules_indent(_: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        rule(0, "positive", "\\n [^ \\t\\n][^\\n]*"),
        rule(1, "positive", "\\n  [^ \\t\\n][^\\n]*"),
        rule(2, "positive", "\\n   [^ \\t\\n][^\\n]*"),
        rule(3, "negative", "\\n  [^ \\t\\n][^\\n]*\\n  [^ \\t\\n]"),
        rule(4, "negative", "\\n   [^ \\t\\n][^\\n]*\\n  [^ \\t\\n]"),
        rule(5, "negative", "\\n\\n|\\n\\t|\\n    [^ \\t\\n]"),
    ]


RULE_BUILDERS: dict[str, Callable[[dict[str, Any]], list[dict[str, Any]]]] = {
    "count:keywords_multiple": rules_keywords,
    "count:conjunctions": rules_conjunctions,
    "count:numbers": rules_numbers,
    "count:word_count_range": rules_word_range,
    "format:list": rules_list,
    "format:sub-bullets": rules_subbullets,
    "format:newline": rules_newline,
    "format:no_bullets_bullets": rules_prose_bullets,
    "format:emoji": rules_emoji,
    "format:thesis": rules_thesis,
    "format:quotes": rules_quotes,
    "format:line_indent": rules_indent,
}


def build(family: str, kwargs: dict[str, Any], max_tokens: int) -> BuiltSpec:
    if family not in RULE_BUILDERS:
        raise KeyError(family)
    rules = [
        {**item, "source_slot": item["slot"], "rule_id": rule_id(family, item["slot"])}
        for item in RULE_BUILDERS[family](dict(kwargs))
    ]
    return BuiltSpec(
        hard_spec={"kind": "text", "max_tokens": int(max_tokens)},
        weak_rules=rules,
    )


MIXED_FAMILIES = ["format:list", "format:newline", "format:quotes", "format:line_indent"]


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
    elif family == "format:line_indent":
        pattern = "^[^ \\t\\n][^\\n]*(\\n[ ]{0,3}[^ \\t\\n][^\\n]*){2,}$"
    else:
        raise KeyError(family)
    return BuiltSpec(
        hard_spec={"kind": "ere", "pattern": pattern, "max_tokens": int(max_tokens)},
        weak_rules=base.weak_rules,
    )
