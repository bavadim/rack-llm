#!/usr/bin/env python3
"""Real hard runtime benchmark for Qwen-backed constrained generation."""

from __future__ import annotations

import argparse
import csv
import gc
import importlib
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter, defaultdict
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
VENDOR_DIR = REPO_ROOT / "experiments" / "004_hard_guide_agreement" / "vendor" / "ifbench"
HARD_GUIDES_DIR = REPO_ROOT / "experiments" / "003_hard_guides" / "code"
RACKET_BATCH = EXPERIMENT_DIR / "code" / "racket_choice_batch.rkt"
DEFAULT_GGUF_MODEL_PATH = Path(
    os.environ.get("RACK_LLM_GGUF_MODEL", "/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
)
DEFAULT_HF_MODEL_PATH = Path(os.environ.get("RACK_LLM_HF_MODEL", "/mnt/storage/models/qwen/Qwen3.5-4B"))

METHODS = ["ours_hard", "guidance_hard", "outlines_hard"]
PILOT_ROWS = 5
FULL_SEEDS = [0, 1, 2, 3, 4]
DEFAULT_PER_SAMPLE_TIMEOUT_SEC = 60.0

sys.path.insert(0, str(HARD_GUIDES_DIR))
from hard_guides import GuideSpec, Unsupported, build_guidance_hard_grammar, build_ours_hard_guide, build_outlines_hard_grammar, check_spec  # noqa: E402
from racket_env import racket_env  # noqa: E402


class SampleTimeoutError(TimeoutError):
    """Raised when one benchmark sample exceeds its configured wall-clock budget."""


@contextmanager
def sample_deadline(seconds: float):
    if seconds <= 0:
        yield
        return

    previous_handler = signal.getsignal(signal.SIGALRM)

    def raise_timeout(_signum: int, _frame: Any) -> None:
        raise SampleTimeoutError(f"sample exceeded {seconds:.1f}s deadline")

    signal.signal(signal.SIGALRM, raise_timeout)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0.0)
        signal.signal(signal.SIGALRM, previous_handler)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def method_spec(row: dict[str, Any], method: str) -> GuideSpec | Unsupported:
    if method == "ours_hard":
        return build_ours_hard_guide(row)
    if method == "guidance_hard":
        return build_guidance_hard_grammar(row)
    if method == "outlines_hard":
        return build_outlines_hard_grammar(row)
    raise ValueError(f"unknown method: {method}")


def runtime_supported(spec: GuideSpec | Unsupported) -> tuple[bool, str]:
    if isinstance(spec, Unsupported):
        return False, spec.reason
    if spec.choices or spec.regex:
        return True, ""
    return False, "UNSUPPORTED_CONSTRAINT: guide spec has neither choices nor regex"


def guidance_regex_is_unbounded(regex: str) -> bool:
    return any(
        re.search(pattern, regex) is not None
        for pattern in [
            r"(?<!\\)\.[*+]",
            r"\\S\+",
            r"\[[^\]]+\][*+]",
            r"\{\d+,\}",
        ]
    )


def method_runtime_supported(method: str, spec: GuideSpec | Unsupported) -> tuple[bool, str]:
    supported, reason = runtime_supported(spec)
    if not supported:
        return supported, reason
    if (
        method == "guidance_hard"
        and isinstance(spec, GuideSpec)
        and spec.regex
        and not spec.choices
        and guidance_regex_is_unbounded(spec.regex)
    ):
        return (
            False,
            "UNSUPPORTED_RUNTIME_UNBOUNDED_REGEX: guidance regex disabled "
            "for unbounded/open regex under hard fullmatch benchmark",
        )
    return True, ""


def supported_paired_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    selected = []
    for row in rows:
        ok = True
        for method in METHODS:
            supported, _reason = method_runtime_supported(method, method_spec(row, method))
            ok = ok and supported
        if ok:
            selected.append(row)
    return selected


def unsupported_rows(rows: list[dict[str, Any]], selected_keys: set[str]) -> list[dict[str, Any]]:
    failures = []
    for row in rows:
        if row["key"] in selected_keys:
            continue
        for method in METHODS:
            spec = method_spec(row, method)
            supported, reason = method_runtime_supported(method, spec)
            if not supported:
                failures.append(
                    {
                        "key": row["key"],
                        "method": method,
                        "seed": None,
                        "outcome": "UNSUPPORTED_CONSTRAINT",
                        "failure_reason": reason,
                        "instruction_id_list": row["instruction_id_list"],
                        "source": "real_runtime",
                    }
                )
    return failures


def run_ours(
    rows: list[dict[str, Any]],
    seeds: list[int],
    model_path: Path,
    scratch_dir: Path,
    per_sample_timeout_sec: float,
) -> list[dict[str, Any]]:
    requests = []
    for row in rows:
        spec = method_spec(row, "ours_hard")
        assert isinstance(spec, GuideSpec) and (spec.choices or spec.regex)
        for seed in seeds:
            requests.append(
                {
                    "run_id": f"{row['key']}:ours_hard:{seed}",
                    "key": row["key"],
                    "prompt": row["prompt"],
                    "choices": spec.choices,
                    "regex": spec.regex,
                    "max_tokens": 512,
                    "deadline_ms": int(per_sample_timeout_sec * 1000) if per_sample_timeout_sec > 0 else None,
                    "seed": seed,
                }
            )
    scratch_dir.mkdir(parents=True, exist_ok=True)
    request_path = scratch_dir / "ours_choice_requests.json"
    output_path = scratch_dir / "ours_choice_raw.jsonl"
    request_path.write_text(json.dumps(requests, ensure_ascii=False, indent=2), encoding="utf-8")
    subprocess.run(
        [
            "racket",
            str(RACKET_BATCH),
            "--model-path",
            str(model_path),
            "--input",
            str(request_path),
            "--output",
            str(output_path),
        ],
        cwd=REPO_ROOT,
        env=racket_env(),
        check=True,
    )
    rows_out = read_jsonl(output_path)
    return [attach_common_fields(row, "ours_hard") for row in rows_out]


def run_guidance(
    rows: list[dict[str, Any]],
    seeds: list[int],
    model_path: Path,
    per_sample_timeout_sec: float,
) -> list[dict[str, Any]]:
    import guidance
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
    lm = guidance.models.Transformers(
        str(model_path),
        echo=False,
        dtype="auto",
        device_map={"": "cuda"},
        trust_remote_code=True,
    )
    output = []
    try:
        for row in rows:
            spec = method_spec(row, "guidance_hard")
            assert isinstance(spec, GuideSpec) and (spec.choices or spec.regex)
            for seed in seeds:
                started = time.perf_counter()
                try:
                    with sample_deadline(per_sample_timeout_sec):
                        if spec.choices:
                            generated = lm + row["prompt"] + guidance.select(spec.choices, name="answer")
                        else:
                            generated = lm + row["prompt"] + guidance.regex(spec.regex, name="answer")
                    text = str(generated["answer"])
                    output.append(
                        generated_row(row, "guidance_hard", seed, text, started, tokenizer, "GENERATED", "")
                    )
                except Exception as error:  # noqa: BLE001 - benchmark rows must serialize failures.
                    output.append(generated_row(row, "guidance_hard", seed, "", started, tokenizer, "ERROR", str(error)))
    finally:
        del lm
        gc.collect()
        try_empty_cuda_cache()
    return output


def run_outlines(
    rows: list[dict[str, Any]],
    seeds: list[int],
    model_path: Path,
    per_sample_timeout_sec: float,
) -> list[dict[str, Any]]:
    import outlines
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_path,
        torch_dtype="auto",
        device_map={"": "cuda"},
        trust_remote_code=True,
    ).eval()
    outlines_model = outlines.from_transformers(model, tokenizer)
    output = []
    try:
        for row in rows:
            spec = method_spec(row, "outlines_hard")
            assert isinstance(spec, GuideSpec) and (spec.choices or spec.regex)
            if spec.choices:
                pattern = choices_regex(spec.choices)
                max_tokens = max(32, max(len(tokenizer.encode(choice, add_special_tokens=False)) for choice in spec.choices) + 16)
            else:
                pattern = spec.regex
                max_tokens = 512
            for seed in seeds:
                started = time.perf_counter()
                try:
                    torch.manual_seed(seed)
                    if torch.cuda.is_available():
                        torch.cuda.manual_seed_all(seed)
                    with sample_deadline(per_sample_timeout_sec):
                        text = str(
                            outlines_model(
                                row["prompt"],
                                output_type=outlines.regex(pattern),
                                max_new_tokens=max_tokens,
                            )
                        )
                    output.append(generated_row(row, "outlines_hard", seed, text, started, tokenizer, "GENERATED", ""))
                except Exception as error:  # noqa: BLE001 - benchmark rows must serialize failures.
                    output.append(generated_row(row, "outlines_hard", seed, "", started, tokenizer, "ERROR", str(error)))
    finally:
        del outlines_model
        del model
        gc.collect()
        try_empty_cuda_cache()
    return output


def choices_regex(choices: list[str]) -> str:
    return "(?:" + "|".join(re.escape(choice) for choice in choices) + ")"


def generated_row(
    row: dict[str, Any],
    method: str,
    seed: int,
    text: str,
    started: float,
    tokenizer: Any,
    outcome: str,
    failure_reason: str,
) -> dict[str, Any]:
    return attach_common_fields(
        {
            "run_id": f"{row['key']}:{method}:{seed}",
            "key": row["key"],
            "method": method,
            "seed": seed,
            "text": text,
            "latency_ms": (time.perf_counter() - started) * 1000.0,
            "generated_tokens": len(tokenizer.encode(text, add_special_tokens=False)) if text else 0,
            "outcome": outcome,
            "failure_reason": failure_reason,
            "source": "real_runtime",
        },
        method,
    )


def attach_common_fields(row: dict[str, Any], method: str) -> dict[str, Any]:
    row["method"] = method
    row.setdefault("source", "real_runtime")
    row.setdefault("official_verifier", None)
    return row


def try_empty_cuda_cache() -> None:
    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


def load_registry():
    sys.path.insert(0, str(VENDOR_DIR))
    return importlib.import_module("instructions_registry")


def non_null(kwargs: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in kwargs.items() if value is not None}


def official_check(row: dict[str, Any], text: str, registry_module: Any) -> bool:
    if not text or not text.strip():
        return False
    results = []
    for index, instruction_id in enumerate(row["instruction_id_list"]):
        instruction_cls = registry_module.INSTRUCTION_DICT[instruction_id]
        instruction = instruction_cls(instruction_id)
        kwargs = non_null(row["kwargs"][index])
        instruction.build_description(**kwargs)
        args = instruction.get_instruction_args()
        if args and "prompt" in args:
            instruction.build_description(prompt=row["prompt"])
        results.append(bool(instruction.check_following(text)))
    return all(results)


def evaluate_official(raw_rows: list[dict[str, Any]], input_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    registry = load_registry()
    row_by_key = {row["key"]: row for row in input_rows}
    evaluated = []
    for raw in raw_rows:
        row = dict(raw)
        if row.get("outcome") == "GENERATED":
            spec = method_spec(row_by_key[row["key"]], row["method"])
            if isinstance(spec, GuideSpec) and spec.choices and row.get("text", "") not in spec.choices:
                row["official_verifier"] = False
                row["outcome"] = "NOT_FOUND"
                row["failure_reason"] = "RUNTIME_INVALID_CHOICE: generated text is not exactly one finite choice"
                evaluated.append(row)
                continue
            if isinstance(spec, GuideSpec) and spec.regex and not spec.choices and not check_spec(spec, row.get("text", "")):
                row["official_verifier"] = False
                row["outcome"] = "NOT_FOUND"
                row["failure_reason"] = "RUNTIME_INVALID_REGEX: generated text does not match the hard regex spec"
                evaluated.append(row)
                continue
            row["official_verifier"] = official_check(row_by_key[row["key"]], row.get("text", ""), registry)
            row["outcome"] = "SOLVED" if row["official_verifier"] else "WRONG"
        else:
            row["official_verifier"] = False
        evaluated.append(row)
    return evaluated


def summarize(raw_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in raw_rows:
        grouped[row["method"]].append(row)
    summary = []
    for method, rows in sorted(grouped.items()):
        counts = Counter(row["outcome"] for row in rows)
        latencies = sorted(float(row["latency_ms"]) for row in rows if row.get("latency_ms") is not None)
        generated_tokens = [int(row.get("generated_tokens") or 0) for row in rows]
        summary.append(
            {
                "method": method,
                "n": len(rows),
                "solve_rate": counts["SOLVED"] / len(rows) if rows else 0.0,
                "wrong_rate": counts["WRONG"] / len(rows) if rows else 0.0,
                "not_found_or_unsupported_rate": (counts["NOT_FOUND"] + counts["UNSUPPORTED_CONSTRAINT"]) / len(rows)
                if rows
                else 0.0,
                "error_rate": counts["ERROR"] / len(rows) if rows else 0.0,
                "median_latency_ms": percentile(latencies, 50),
                "p95_latency_ms": percentile(latencies, 95),
                "mean_generated_tokens": sum(generated_tokens) / len(generated_tokens) if generated_tokens else 0.0,
                "attempts": 1,
            }
        )
    return summary


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    index = (len(values) - 1) * p / 100.0
    lower = int(index)
    upper = min(lower + 1, len(values) - 1)
    weight = index - lower
    return values[lower] * (1 - weight) + values[upper] * weight


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = list(rows[0].keys()) if rows else ["method", "n"]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def run(
    rows: list[dict[str, Any]],
    seeds: list[int],
    gguf_model_path: Path,
    hf_model_path: Path,
    per_sample_timeout_sec: float,
    max_selected_rows: int | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    selected = supported_paired_rows(rows)
    if max_selected_rows is not None:
        selected = selected[:max_selected_rows]
    selected_keys = {row["key"] for row in selected}
    failures = unsupported_rows(rows, selected_keys)
    raw = []
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".scratch-hard-", dir=RESULTS_DIR) as scratch:
        raw.extend(run_ours(selected, seeds, gguf_model_path, Path(scratch), per_sample_timeout_sec))
    raw.extend(run_guidance(selected, seeds, hf_model_path, per_sample_timeout_sec))
    raw.extend(run_outlines(selected, seeds, hf_model_path, per_sample_timeout_sec))
    return evaluate_official(raw, selected), failures


def copy_outputs(names: list[str]) -> None:
    for name in names:
        source = RESULTS_DIR / name
        target = ROOT_DATA_DIR / name
        shutil.copyfile(source, target)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["pilot", "full"], required=True)
    parser.add_argument("--gguf-model-path", type=Path, default=DEFAULT_GGUF_MODEL_PATH)
    parser.add_argument("--hf-model-path", type=Path, default=DEFAULT_HF_MODEL_PATH)
    parser.add_argument("--per-sample-timeout-sec", type=float, default=DEFAULT_PER_SAMPLE_TIMEOUT_SEC)
    args = parser.parse_args(argv)

    rows = read_jsonl(ROOT_DATA_DIR / "hard_ifbench_subset.jsonl")
    max_selected_rows = None
    if args.mode == "pilot":
        max_selected_rows = PILOT_ROWS
        seeds = [0]
        raw_name = "014_hard_runtime_pilot_raw.jsonl"
        summary_name = "014_hard_runtime_pilot_summary.csv"
        failures_name = "014_hard_runtime_failures.jsonl"
    else:
        rows = rows
        seeds = FULL_SEEDS
        raw_name = "012_hard_real_raw.jsonl"
        summary_name = "012_hard_real_summary.csv"
        failures_name = "012_hard_runtime_failures.jsonl"

    raw, failures = run(
        rows,
        seeds,
        args.gguf_model_path,
        args.hf_model_path,
        args.per_sample_timeout_sec,
        max_selected_rows,
    )
    write_jsonl(RESULTS_DIR / raw_name, raw)
    write_jsonl(RESULTS_DIR / failures_name, failures)
    write_csv(RESULTS_DIR / summary_name, summarize(raw))
    if args.mode == "full":
        copy_outputs([raw_name, summary_name, failures_name])
    print(json.dumps({"mode": args.mode, "raw_rows": len(raw), "failures": len(failures)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
