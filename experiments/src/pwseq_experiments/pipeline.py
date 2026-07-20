from __future__ import annotations

import json
import math
import os
import re
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np

from .common import ARTIFACTS, DATA, EXPERIMENTS, REPO, assert_frozen, atomic_jsonl_command, file_hash, frozen_manifest, issue, jsonl_count, load_config, python_env, read_jsonl, stable_hash, write_json, write_jsonl, write_jsonl_once
from .evaluator import official_check_many
from .fuse import FuseModel, fit_fuse, predict_fuse
from .metrics import (
    classification_metrics, effective_rank, equal_probability, max_coverage,
    majority_probability, operating_metrics, selective_curve,
)

RACKET_RUNNER = EXPERIMENTS / "racket" / "rack_runner.rkt"
ARTIFACT_SCHEMA_VERSION = 4


def temperature_policy(config: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return the single frozen calibration/deployment temperature policy."""
    config = load_config() if config is None else config
    primary = float(config["primary_temperature"])
    if primary <= 0:
        raise ValueError("primary_temperature must be positive")
    if config.get("posterior_policy") != {
        "good_multiplier": 1.0, "bad_multiplier": 0.0,
    }:
        raise ValueError("primary posterior policy must be frozen to good=1, bad=0")
    seed_groups = {
        "primary_calibration_seeds": list(map(int, config["primary_calibration_seeds"])),
        "candidate_evaluation_seeds": list(map(int, config["candidate_evaluation_seeds"])),
    }
    for name, seeds in seed_groups.items():
        if not seeds or len(seeds) != len(set(seeds)) or any(seed < 0 for seed in seeds):
            raise ValueError(f"{name} must contain unique non-negative seeds")
    expected_seed_groups = {
        "primary_calibration_seeds": list(range(20)),
        "candidate_evaluation_seeds": list(range(20)),
    }
    if seed_groups != expected_seed_groups:
        raise ValueError(
            "the paper protocol fixes calibration/evaluation seeds to 0..19/0..19"
        )
    return {
        "primary_temperature": primary,
        **seed_groups,
    }


def _has_temperature(row: dict[str, Any], temperatures: list[float]) -> bool:
    value = float(row.get("temperature", 1.0))
    return any(math.isclose(value, expected, rel_tol=0.0, abs_tol=1e-12)
               for expected in temperatures)


def _dataset_revision() -> str:
    manifest = json.loads((DATA / "manifest.json").read_text(encoding="utf-8"))
    revision = str(manifest.get("experiment_revision", ""))
    if not revision:
        raise RuntimeError("dataset manifest has no experiment_revision")
    return revision


def rule_schema_id(family: str, level: float) -> str:
    """Stable calibration schema identity, independent of concrete matchers."""
    noise = int(round(float(level) * 100))
    return f"pwseq-ifbench/{_dataset_revision()}/{family}/noise-{noise:02d}@1"


def bind_rule_schemas(
    rows: list[dict[str, Any]], level: float,
) -> list[dict[str, Any]]:
    revision = _dataset_revision()
    noise = int(round(float(level) * 100))
    return [{
        **row,
        "weak_schema_id": rule_schema_id(str(row["family"]), level),
        "weak_schema_revision": revision,
        "weak_schema_noise": noise,
        "weak_schema_signature": stable_hash([
            {"rule_id": rule["rule_id"], "polarity": rule["polarity"]}
            for rule in row["weak_rules"]
        ]),
    } for row in rows]


def _model_config(model_name: str) -> dict[str, Any]:
    config = load_config()
    return config["main_model"] if model_name.startswith("main") else config["replication_model"]


def _budgets(model_name: str) -> list[int]:
    config = load_config()
    if model_name == "main":
        return list(config["budgets"])
    return list(config["replication_budgets"])


def render_instances(rows: list[dict[str, Any]], model_name: str) -> list[dict[str, Any]]:
    from transformers import AutoTokenizer

    model = _model_config(model_name)
    tokenizer = AutoTokenizer.from_pretrained(model["hf_path"], local_files_only=True)
    rendered = []
    for row in rows:
        messages = [{"role": "user", "content": row["prompt"]}]
        try:
            prompt = tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
            )
        except TypeError:
            prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        rendered.append({**row, "model_prompt": prompt, "model_family": model["family"]})
    return rendered


def _run_racket(stage: str, args: list[str], output: Path, expected_rows: int | None = None) -> Path:
    config = load_config()
    frozen = frozen_manifest()
    if frozen is None:
        raise RuntimeError("experiment is not frozen; run `make -C experiments freeze`")
    runtime = config.get("runtime", {})
    resolved = list(args)
    if "--context-size" not in resolved:
        resolved.extend(["--context-size", str(runtime.get("context_size", 1024))])
    if "--model-threads" not in resolved:
        resolved.extend(["--model-threads", str(runtime.get("model_threads", 1))])
    if "--cohort-width" not in resolved:
        resolved.extend(["--cohort-width", str(runtime.get("cohort_width", 1))])
    for option, key, default in (
        ("--batch-size", "batch_size", 8192),
        ("--ubatch-size", "ubatch_size", 512),
        ("--batch-threads", "batch_threads", 1),
        ("--factor-threads", "factor_threads", 1),
    ):
        if option not in resolved:
            resolved.extend([option, str(runtime.get(key, default))])
    env = python_env()
    regex_threads = int(runtime.get("regex_threads", 1))
    env["OMP_NUM_THREADS"] = str(max(1, regex_threads))
    env["OMP_DYNAMIC"] = "FALSE"
    devices = list(runtime.get("gpu_devices", [0]))
    worker_match = re.search(r"[.]worker([0-9]+)$", stage)
    worker = int(worker_match.group(1)) if worker_match else 0
    if devices:
        env["CUDA_VISIBLE_DEVICES"] = str(devices[worker % len(devices)])
    resource_fingerprint = stable_hash({
        "artifact_schema_version": ARTIFACT_SCHEMA_VERSION,
        "frozen_sources": {
            "files": frozen.get("files", {}),
            "external_files": frozen.get("external_files", {}),
            "llama_cpp_revision": frozen.get("llama_cpp_revision"),
            "ifbench_revision": frozen.get("ifbench_revision"),
        },
        "runtime": runtime,
        "worker": worker,
        "visible_gpu": env.get("CUDA_VISIBLE_DEVICES"),
    })
    if "--runtime-fingerprint" not in resolved:
        resolved.extend(["--runtime-fingerprint", resource_fingerprint])
    return atomic_jsonl_command(
        stage, ["racket", str(RACKET_RUNNER), *resolved],
        output, expected_rows=expected_rows, cwd=REPO, env=env,
    )


def _replace_option(args: list[str], option: str, value: Path) -> list[str]:
    updated = list(args)
    try:
        index = updated.index(option)
    except ValueError as exc:
        raise ValueError(f"missing required runner option {option}") from exc
    updated[index + 1] = str(value)
    return updated


def _run_racket_sharded(
    stage: str,
    args: list[str],
    output: Path,
    *,
    records_per_input: int,
) -> Path:
    """Run independent prompt shards and restore canonical serial ordering."""
    started = time.perf_counter()
    config = load_config()
    requested = int(config.get("runtime", {}).get("generation_workers", 1))
    input_path = Path(args[args.index("--input") + 1])
    input_rows = read_jsonl(input_path)
    workers = min(requested, len(input_rows))
    expected = len(input_rows) * records_per_input
    if workers <= 1:
        return _run_racket(stage, args, output, expected)

    shard_root = ARTIFACTS / "shards" / stage.replace("/", "_")
    pieces: list[tuple[Path, Path, int]] = []
    rows_by_worker: list[list[dict[str, Any]]] = [[] for _ in range(workers)]
    for index, row in enumerate(input_rows):
        rows_by_worker[index % workers].append(row)
    for worker, shard_rows in enumerate(rows_by_worker):
        shard_input = shard_root / f"input-{worker:02d}.jsonl"
        shard_output = shard_root / f"output-{worker:02d}.jsonl"
        write_jsonl(shard_input, shard_rows)
        pieces.append((shard_input, shard_output, len(shard_rows)))

    def run_piece(piece: tuple[Path, Path, int]) -> Path:
        shard_input, shard_output, count = piece
        shard_args = _replace_option(args, "--input", shard_input)
        shard_args = _replace_option(shard_args, "--output", shard_output)
        worker = int(shard_output.stem.rsplit("-", 1)[-1])
        return _run_racket(
            f"{stage}.worker{worker}", shard_args, shard_output,
            count * records_per_input,
        )

    with ThreadPoolExecutor(max_workers=workers) as executor:
        shard_outputs = list(executor.map(run_piece, pieces))

    prompt_order = {row["id"]: index for index, row in enumerate(input_rows)}
    merged = [row for piece in shard_outputs for row in read_jsonl(piece)]
    if len(merged) != expected:
        raise RuntimeError(
            f"{stage} shard merge produced {len(merged)} rows; expected {expected}"
        )
    unknown = sorted({row.get("prompt_id") for row in merged} - set(prompt_order))
    if unknown:
        raise RuntimeError(f"{stage} shard merge contains unknown prompts: {unknown}")
    merged.sort(key=lambda row: (
        prompt_order[row["prompt_id"]],
        int(row.get("seed", -1)),
        int(row.get("sample_index", -1)),
        int(row.get("checkpoint_budget", -1)),
        str(row.get("record_type", "")),
    ))
    identities = [
        (row.get("prompt_id"), row.get("seed"), row.get("sample_index"),
         row.get("checkpoint_budget"), row.get("record_type"))
        for row in merged
    ]
    if len(identities) != len(set(identities)):
        raise RuntimeError(f"{stage} shard merge contains duplicate records")
    write_jsonl(output, merged)
    worker_meta = [
        json.loads(path.with_suffix(path.suffix + ".meta.json").read_text(encoding="utf-8"))
        for path in shard_outputs
    ]
    worker_seconds = sum(float(meta["wall_seconds"]) for meta in worker_meta)
    wall_seconds = time.perf_counter() - started
    write_json(output.with_suffix(output.suffix + ".meta.json"), {
        "stage": stage, "workers": workers, "rows": len(merged),
        "expected_rows": expected, "input_sha256": file_hash(input_path),
        "output_sha256": file_hash(output),
        "shards": [file_hash(path) for path in shard_outputs],
        "wall_seconds": wall_seconds,
        "worker_seconds": worker_seconds,
        "rows_per_second": len(merged) / wall_seconds if wall_seconds > 0.0 else 0.0,
    })
    return output


def _candidate_id(row: dict[str, Any], model_family: str) -> str:
    return stable_hash({
        "prompt_id": row["prompt_id"], "model_family": model_family,
        "temperature": row["temperature"], "seed": row["seed"],
        "sample_index": row["sample_index"], "text": row["text"],
        "token_ids": row["token_ids"],
    })


def _candidate_key(row: dict[str, Any]) -> tuple[str, float, int, int]:
    return (
        str(row["prompt_id"]), round(float(row["temperature"]), 12),
        int(row["seed"]), int(row["sample_index"]),
    )


def _import_candidate_cache(
    model: dict[str, Any], rendered: list[dict[str, Any]],
    expected: set[tuple[str, float, int, int]], model_name: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Import frozen hard-only strings only after full lineage validation."""
    config = load_config()
    specification = config.get("candidate_cache_import")
    lineage: dict[str, Any] = {
        "status": "not_configured", "model": model_name,
        "model_family": model["family"], "imported_rows": 0,
    }
    if (
        not specification
        or specification.get("model_family") != model["family"]
        or model_name not in specification.get("eligible_model_names", [])
    ):
        return [], lineage
    source = (
        EXPERIMENTS / "artifacts" / str(specification["source_run_id"])
        / str(specification["source_relative_path"])
    )
    source_root = source.parents[1]
    source_manifest_path = source_root / "frozen_manifest.json"
    source_instances_path = source_root / str(
        specification["source_instances_relative_path"]
    )
    lineage.update({
        "source_run_id": specification["source_run_id"],
        "source_path": str(source),
        "expected_sha256": specification["sha256"],
        "source_manifest_path": str(source_manifest_path),
        "source_instances_path": str(source_instances_path),
    })
    if not source.is_file():
        lineage["status"] = "unavailable"
        return [], lineage
    for required in (source_manifest_path, source_instances_path):
        if not required.is_file():
            raise RuntimeError(f"candidate cache lineage file is missing: {required}")

    def require_hash(path: Path, expected_hash: str, label: str) -> str:
        actual = file_hash(path)
        if actual != expected_hash:
            raise RuntimeError(
                f"candidate cache {label} hash mismatch: {actual} != {expected_hash}"
            )
        return actual

    actual_hash = file_hash(source)
    if actual_hash != specification["sha256"]:
        raise RuntimeError(
            f"candidate cache hash mismatch: {actual_hash} != "
            f"{specification['sha256']}"
        )
    source_manifest_hash = require_hash(
        source_manifest_path, specification["source_frozen_manifest_sha256"],
        "frozen manifest",
    )
    source_instances_hash = require_hash(
        source_instances_path, specification["source_instances_sha256"],
        "rendered instances",
    )
    source_manifest = json.loads(source_manifest_path.read_text(encoding="utf-8"))
    expected_manifest = {
        "run_id": specification["source_run_id"],
        "artifact_schema_version": specification["source_manifest_schema_version"],
        "protocol_version": specification["source_protocol_revision"],
        "git_revision": specification["source_git_revision"],
        "llama_cpp_revision": specification["source_llama_cpp_revision"],
    }
    manifest_mismatches = {
        key: {"expected": expected, "actual": source_manifest.get(key)}
        for key, expected in expected_manifest.items()
        if source_manifest.get(key) != expected
    }
    if manifest_mismatches:
        raise RuntimeError(
            f"candidate cache frozen manifest mismatch: {manifest_mismatches}"
        )
    if config["native"]["llama_cpp_commit"] != source_manifest["llama_cpp_revision"]:
        raise RuntimeError("candidate cache llama.cpp revision differs from current run")
    if config.get("runtime") != specification.get("source_runtime"):
        raise RuntimeError("candidate cache execution profile differs from current run")
    source_gguf_path = str(specification["source_gguf_path"])
    source_gguf_hash = source_manifest.get("external_files", {}).get(source_gguf_path)
    if source_gguf_hash != specification["source_gguf_sha256"]:
        raise RuntimeError("candidate cache source GGUF is not bound by frozen manifest")
    current_gguf_hash = file_hash(Path(model["gguf_path"]))
    if current_gguf_hash != source_gguf_hash:
        raise RuntimeError(
            "candidate cache model mismatch: current GGUF differs from source GGUF"
        )
    dataset_files = specification.get("dataset_files", {})
    actual_dataset_hashes = {
        name: file_hash(DATA / name) for name in dataset_files
    }
    mismatches = {
        name: {"expected": digest, "actual": actual_dataset_hashes[name]}
        for name, digest in dataset_files.items()
        if actual_dataset_hashes[name] != digest
    }
    if mismatches:
        raise RuntimeError(f"candidate cache dataset lineage mismatch: {mismatches}")
    instances = {str(row["id"]): row for row in rendered}
    source_instance_rows = read_jsonl(source_instances_path)
    source_instance_ids = [str(row["id"]) for row in source_instance_rows]
    if len(source_instance_ids) != len(set(source_instance_ids)):
        raise RuntimeError("candidate cache rendered instances contain duplicate IDs")
    source_instances = {
        str(row["id"]): row for row in source_instance_rows
    }
    source_rows = read_jsonl(source)
    tokenizer_fingerprints = {
        str(row.get("tokenizer_fingerprint", "")) for row in source_rows
    }
    if tokenizer_fingerprints != {specification["tokenizer_fingerprint"]}:
        raise RuntimeError(
            "candidate cache tokenizer fingerprint is missing or not unique: "
            f"{sorted(tokenizer_fingerprints)}"
        )
    source_candidate_versions = sorted({
        int(row.get("artifact_schema_version", -1)) for row in source_rows
    })
    if source_candidate_versions != [int(specification["source_candidate_schema_version"])]:
        raise RuntimeError(
            "candidate cache artifact schema mismatch: "
            f"{source_candidate_versions}"
        )
    runtime_fingerprints = sorted({
        str(row.get("runtime_fingerprint", "")) for row in source_rows
    })
    if len(runtime_fingerprints) != 1 or not runtime_fingerprints[0]:
        raise RuntimeError("candidate cache runtime fingerprint is missing or not unique")
    imported: list[dict[str, Any]] = []
    seen: set[tuple[str, float, int, int]] = set()
    matched_prompt_ids: set[str] = set()
    allowed_splits = set(map(str, specification["allowed_splits"]))
    for row in source_rows:
        key = _candidate_key(row)
        if key not in expected or str(row.get("split")) not in allowed_splits:
            continue
        instance = instances.get(key[0])
        if instance is None:
            continue
        source_instance = source_instances.get(key[0])
        if source_instance is None:
            raise RuntimeError(
                f"candidate cache has no rendered source instance for {key[0]}"
            )
        if key in seen:
            raise RuntimeError(f"duplicate imported candidate key: {key}")
        prompt_fields = ("model_prompt", "hard_spec", "max_tokens")
        prompt_mismatches = {
            field: {
                "source": source_instance.get(field), "current": instance.get(field),
            }
            for field in prompt_fields
            if source_instance.get(field) != instance.get(field)
        }
        if prompt_mismatches:
            raise RuntimeError(
                f"candidate cache prompt mismatch for {key[0]}: {prompt_mismatches}"
            )
        if source_instance.get("hard_spec", {}).get("kind") != "text":
            raise RuntimeError(
                "candidate cache import is restricted to free-text hard envelopes"
            )
        if (
            row.get("model_family") != model["family"]
            or row.get("family") != instance["family"]
            or row.get("split") != instance["split"]
            or source_instance.get("model_family") != model["family"]
            or source_instance.get("family") != instance["family"]
            or source_instance.get("split") != instance["split"]
            or row.get("status") != "found"
            or row.get("hard_valid") is not True
            or row.get("candidate_id") != _candidate_id(row, model["family"])
        ):
            raise RuntimeError(f"invalid imported candidate metadata: {key}")
        seen.add(key)
        matched_prompt_ids.add(key[0])
        imported.append({
            **row, "artifact_schema_version": ARTIFACT_SCHEMA_VERSION,
            "terminal_mass": False, "calibration_fingerprint": False,
        })
    lineage.update({
        "status": "imported", "source_sha256": actual_hash,
        "source_rows": len(source_rows), "imported_rows": len(imported),
        "imported_keys_sha256": stable_hash(sorted(seen)),
        "imported_prompt_ids_sha256": stable_hash(sorted(matched_prompt_ids)),
        "imported_prompt_contract_sha256": stable_hash([
            {
                "id": prompt_id,
                "model_prompt": source_instances[prompt_id]["model_prompt"],
                "hard_spec": source_instances[prompt_id]["hard_spec"],
                "max_tokens": source_instances[prompt_id]["max_tokens"],
            }
            for prompt_id in sorted(matched_prompt_ids)
        ]),
        "dataset_files": dataset_files,
        "source_frozen_manifest_sha256": source_manifest_hash,
        "source_manifest": expected_manifest,
        "source_rendered_instances_sha256": source_instances_hash,
        "source_gguf_sha256": source_gguf_hash,
        "current_gguf_sha256": current_gguf_hash,
        "tokenizer_fingerprint": next(iter(tokenizer_fingerprints)),
        "source_runtime_fingerprint": runtime_fingerprints[0],
        "source_runtime": specification["source_runtime"],
        "source_candidate_artifact_schema_versions": source_candidate_versions,
        "normalized_artifact_schema_version": ARTIFACT_SCHEMA_VERSION,
        "normalized_fields": {
            "terminal_mass": False, "calibration_fingerprint": False,
        },
        "allowed_splits": sorted(allowed_splits),
        "hard_envelope": "text-only",
    })
    return imported, lineage


def generate_pool(model_name: str, splits: list[str], *, main_stream: bool = False) -> Path:
    assert_frozen()
    config = load_config()
    policy = temperature_policy(config)
    model = _model_config(model_name)
    rows = []
    for split in splits:
        rows.extend(read_jsonl(DATA / f"{split}.jsonl"))
    if main_stream:
        rows = [row for row in rows if row["split"] != "calibration"]
    rendered = render_instances(rows, model_name)
    input_path = ARTIFACTS / "inputs" / f"{model_name}_{'main' if main_stream else 'candidate'}_instances.jsonl"
    write_jsonl(input_path, rendered)
    pieces: list[Path] = []
    if main_stream:
        protocols = [(
            policy["primary_temperature"], config["generation_seeds"],
            max(_budgets(model_name)), None,
        )]
    else:
        # Calibration and deployment use one frozen distribution (T=1.0).
        # Candidate-level dev/test evaluation remains an independent fixed
        # twenty-seed pool.
        protocols = [
            (
                policy["primary_temperature"],
                policy["primary_calibration_seeds"], 1, {"calibration"},
            ),
            (
                policy["primary_temperature"],
                policy["candidate_evaluation_seeds"], 1,
                {split for split in splits if split != "calibration"},
            ),
        ]
    expected_keys = {
        (str(row["id"]), round(float(protocol_temperature), 12), int(seed), sample)
        for protocol_temperature, protocol_seeds, samples, allowed_splits in protocols
        for row in rendered
        if allowed_splits is None or row["split"] in allowed_splits
        for seed in protocol_seeds
        for sample in range(samples)
    }
    imported: list[dict[str, Any]] = []
    lineage = {
        "status": "not_applicable", "model": model_name,
        "model_family": model["family"], "imported_rows": 0,
    }
    if not main_stream:
        imported, lineage = _import_candidate_cache(
            model, rendered, expected_keys, model_name
        )
    imported_keys = {_candidate_key(row) for row in imported}
    piece_index = 0
    for protocol_index, (temperature, seeds, samples, allowed_splits) in enumerate(protocols):
        protocol_rows = [row for row in rendered if allowed_splits is None or row["split"] in allowed_splits]
        if not protocol_rows:
            continue
        missing_groups: dict[tuple[int, ...], list[dict[str, Any]]] = defaultdict(list)
        for row in protocol_rows:
            missing = tuple(
                int(seed) for seed in seeds
                if any(
                    (str(row["id"]), round(float(temperature), 12), int(seed), sample)
                    not in imported_keys
                    for sample in range(samples)
                )
            )
            if missing:
                missing_groups[missing].append(row)
        for missing_seeds, missing_rows in sorted(missing_groups.items()):
            protocol_input = (
                input_path if allowed_splits is None and len(missing_groups) == 1
                else ARTIFACTS / "inputs"
                / f"{model_name}_candidate_{protocol_index}_{piece_index}_instances.jsonl"
            )
            write_jsonl(protocol_input, protocol_rows)
            if missing_rows != protocol_rows:
                write_jsonl(protocol_input, missing_rows)
            output = (
                ARTIFACTS / "raw"
                / f"{model_name}_{'main' if main_stream else 'candidate'}_{piece_index}.jsonl"
            )
            _run_racket_sharded(
                f"generate.{model_name}.{piece_index}",
                [
                    "--mode", "candidates", "--input", str(protocol_input),
                    "--output", str(output), "--model", model["gguf_path"],
                    "--temperature", str(temperature),
                    "--seeds", ",".join(map(str, missing_seeds)),
                    "--samples-per-seed", str(samples),
                    "--max-attempts", str(config["hard_max_attempts"]),
                    "--deadline-ms", str(config["hard_deadline_ms"]),
                ], output, records_per_input=len(missing_seeds) * samples,
            )
            pieces.append(output)
            piece_index += 1
    merged = list(imported)
    for piece in pieces:
        for row in read_jsonl(piece):
            row["model_family"] = model["family"]
            row["candidate_id"] = _candidate_id(row, model["family"])
            merged.append(row)
    prompt_order = {str(row["id"]): index for index, row in enumerate(rendered)}
    merged.sort(key=lambda row: (
        prompt_order[str(row["prompt_id"])], round(float(row["temperature"]), 12),
        int(row["seed"]), int(row["sample_index"]),
    ))
    destination = ARTIFACTS / "raw" / f"{model_name}_{'main' if main_stream else 'candidate'}_pool.jsonl"
    write_jsonl(destination, merged)
    actual_keys = [_candidate_key(row) for row in merged]
    if len(actual_keys) != len(set(actual_keys)) or set(actual_keys) != expected_keys:
        raise RuntimeError(
            "candidate merge protocol mismatch: "
            f"rows={len(actual_keys)} unique={len(set(actual_keys))} "
            f"expected={len(expected_keys)}"
        )
    lineage.update({
        "generated_rows": sum(jsonl_count(piece) for piece in pieces),
        "destination_rows": len(merged),
        "destination_sha256": file_hash(destination),
    })
    write_json(
        ARTIFACTS / "reports"
        / f"{model_name}_{'main' if main_stream else 'candidate'}_cache_lineage.json",
        lineage,
    )
    return destination


def evaluate_candidates(instances_path: Path, candidates_path: Path, output_path: Path) -> None:
    instances = {row["id"]: row for row in read_jsonl(instances_path)}
    candidates = read_jsonl(candidates_path)
    workers = int(load_config().get("runtime", {}).get("evaluator_workers", os.cpu_count() or 1))
    try:
        passed_values = official_check_many(
            [(instances[row["prompt_id"]], row["text"]) for row in candidates],
            workers=max(1, workers),
        )
    except Exception as exc:
        issue("official_evaluation", exc, candidates=len(candidates))
        raise
    labels = [{
        "candidate_id": candidate["candidate_id"],
        "prompt_id": candidate["prompt_id"],
        "gold_pass": passed,
    } for candidate, passed in zip(candidates, passed_values, strict=True)]
    if len(labels) != len(candidates):
        raise RuntimeError("official candidate evaluation cardinality mismatch")
    write_jsonl(output_path, labels)


def all_instances() -> list[dict[str, Any]]:
    rows = []
    for split in ["calibration", "dev", "test", "test_official"]:
        rows.extend(read_jsonl(DATA / f"{split}.jsonl"))
    return rows


def apply_noise(rows: list[dict[str, Any]], level: float) -> list[dict[str, Any]]:
    overlays = ({
        row["instance_id"]: row
        for row in read_jsonl(DATA / f"noise_{int(level * 100):02d}.jsonl")
    } if level else {})
    output = []
    for row in rows:
        rules = [{
            **rule,
            "source_slot": rule["slot"],
        } for rule in row["weak_rules"]]
        for change in overlays.get(row["id"], {}).get("changes", []):
            slot = change["slot"]
            rules[slot] = {
                **rules[slot],
                "polarity": change["polarity"],
                "pattern": change["pattern"],
                "noise_type": change["noise_type"],
            }
        output.append({**row, "weak_rules": rules})
    return bind_rule_schemas(output, level)


def observe(
    model_name: str,
    candidates: Path,
    rows: list[dict[str, Any]],
    level: float,
    *,
    stream: str = "candidate",
) -> Path:
    model = _model_config(model_name)
    stem = f"{model_name}_noise_{int(level*100):02d}_{stream}"
    input_path = ARTIFACTS / "inputs" / f"{stem}.jsonl"
    output_path = ARTIFACTS / "observations" / f"{stem}.jsonl"
    schema_rows = bind_rule_schemas(rows, level)
    write_jsonl(input_path, schema_rows)
    _run_racket(
        f"observe.{model_name}.{level}.{stream}",
        [
            "--mode", "observe", "--input", str(input_path), "--candidates", str(candidates),
            "--output", str(output_path), "--model", model["gguf_path"],
        ], output_path, jsonl_count(candidates),
    )
    failures = [
        row for row in read_jsonl(output_path)
        if row.get("record_type") == "observe_error"
    ]
    if failures:
        raise RuntimeError(f"weak observation failed: {failures[:5]}")
    return output_path


def _schema_inventory(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    inventory: dict[str, dict[str, Any]] = {}
    for family in sorted({str(row["family"]) for row in rows}):
        family_rows = [row for row in rows if str(row["family"]) == family]
        schema_ids = {str(row["weak_schema_id"]) for row in family_rows}
        signatures = {str(row["weak_schema_signature"]) for row in family_rows}
        if len(schema_ids) != 1 or len(signatures) != 1:
            raise RuntimeError(
                f"family {family} does not have one stable rule schema: "
                f"ids={sorted(schema_ids)} signatures={sorted(signatures)}"
            )
        inventory[family] = {
            "schema_id": next(iter(schema_ids)),
            "schema_signature": next(iter(signatures)),
            "rule_ids": [rule["rule_id"] for rule in family_rows[0]["weak_rules"]],
            "polarities": [rule["polarity"] for rule in family_rows[0]["weak_rules"]],
        }
    return inventory


def _score_rows_with_explicit_calibration_status(
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    output = []
    for row in records:
        if row.get("record_type") == "score":
            output.append({**row, "calibration_status": "OK"})
        elif row.get("record_type") == "score_error" and row.get("candidate_id"):
            output.append({
                **row, "record_type": "score", "posterior": None,
                "calibration_status": "ERROR",
                "calibration_error": row.get("message", "calibration unavailable"),
            })
        else:
            output.append(row)
    return output


def fit_score(
    model_name: str,
    candidates: Path,
    rows: list[dict[str, Any]],
    level: float,
    *,
    observations_path: Path | None = None,
) -> tuple[Path, Path]:
    model = _model_config(model_name)
    policy = temperature_policy()
    fit_temperatures = [policy["primary_temperature"]]
    noise = int(level * 100)
    stem = f"{model_name}_noise_{noise:02d}"
    schema_rows = bind_rule_schemas(rows, level)
    schemas = _schema_inventory(schema_rows)
    observed = observations_path or observe(
        model_name, candidates, schema_rows, level
    )
    input_path = ARTIFACTS / "inputs" / f"{stem}_instances.jsonl"
    output_path = ARTIFACTS / "scores" / f"{stem}.jsonl"
    raw_output_path = ARTIFACTS / "scores" / f"{stem}_raw.jsonl"
    calibrations = ARTIFACTS / "calibrations" / model_name / f"noise_{noise:02d}"
    write_jsonl(input_path, schema_rows)
    _run_racket(
        f"fit_score.{model_name}.{level}",
        [
            "--mode", "fit-score", "--input", str(input_path),
            "--candidates", str(observed),
            "--output", str(raw_output_path), "--calibrations-dir", str(calibrations),
        ], raw_output_path,
    )
    scored = read_jsonl(raw_output_path)
    failures = [row for row in scored if row.get("record_type") == "fit_error"]
    failure_by_family = {str(row["family"]): row for row in failures}
    successful_families = {
        str(row["family"]) for row in scored if row.get("record_type") == "fit"
    }
    missing_families = sorted(set(schemas) - successful_families - set(failure_by_family))
    for family in missing_families:
        failure_by_family[family] = {
            "record_type": "fit_error", "family": family,
            "error": "runner returned neither fit nor fit_error",
        }
    for family, failure in sorted(failure_by_family.items()):
        message = str(
            failure.get("error", failure.get("message", "calibration fit failed"))
        )
        issue(
            "calibration.fit", RuntimeError(message),
            model=model_name, noise=level, family=family,
            schema_id=schemas.get(family, {}).get("schema_id"),
        )
    expected_scores = sum(
        row.get("status") == "found" and bool(row.get("hard_valid"))
        for row in read_jsonl(candidates)
    )
    actual_scores = sum(
        row.get("record_type") in {"score", "score_error"}
        and bool(row.get("candidate_id"))
        for row in scored
    )
    if actual_scores != expected_scores:
        raise RuntimeError(
            f"fit-score produced {actual_scores} scores; expected {expected_scores}"
        )
    write_jsonl(
        ARTIFACTS / "reports" / f"{stem}_weak_diagnostics.jsonl",
        [
            {
                "model": model_name, "noise": level, "family": row["family"],
                "fit_temperatures": fit_temperatures,
                "fit_training_rows": row["fit_training_rows"],
                **row["diagnostics"],
            }
            for row in scored if row.get("record_type") == "fit"
        ],
    )
    tokenizer_fingerprints = sorted({
        row["tokenizer_fingerprint"] for row in read_jsonl(candidates)
        if row.get("tokenizer_fingerprint")
    })
    training_rows = [
        {
            "candidate_id": row.get("candidate_id"),
            "prompt_id": row["prompt_id"],
            "family": row["family"],
            "temperature": float(row.get("temperature", 1.0)),
            "seed": row["seed"],
            "sample_index": row["sample_index"],
            "labels": row["labels"],
            "rule_ids": row["rule_ids"],
            "schema_id": row.get("schema_id", row.get("weak_schema_id")),
        }
        for row in read_jsonl(observed)
        if row.get("record_type") == "observation"
        and row["split"] == "calibration"
        and _has_temperature(row, fit_temperatures)
    ]
    training_rows_by_family = {
        family: sum(row["family"] == family for row in training_rows)
        for family in sorted(schemas)
    }
    cohort_status = {
        family: {
            "status": "OK" if family in successful_families else "ERROR",
            "schema_id": schemas[family]["schema_id"],
            "fit_training_rows": training_rows_by_family[family],
            **({} if family in successful_families else {
                "error": failure_by_family[family].get(
                    "error", failure_by_family[family].get("message", "fit failed")
                ),
            }),
        }
        for family in sorted(schemas)
    }
    manifest = {
        "artifact_schema_version": 4,
        "dataset_revision": _dataset_revision(),
        "model_name": model_name,
        "base_model_family": model["family"],
        "noise_level": level,
        "fit_temperatures": fit_temperatures,
        "fit_training_rows": len(training_rows),
        "fit_training_rows_by_family": training_rows_by_family,
        "fit_observations_sha256": stable_hash(training_rows),
        "rule_schemas": schemas,
        "cohorts": cohort_status,
        "tokenizer_fingerprints": tokenizer_fingerprints,
        "instances_sha256": file_hash(input_path),
        "scored_observations_sha256": file_hash(observed),
        "candidate_pool_sha256": file_hash(candidates),
        "calibration_fingerprints": {
            row["family"]: row["calibration_fingerprint"]
            for row in scored if row.get("record_type") == "fit"
        },
    }
    runner_counts = {
        row["family"]: int(row["fit_training_rows"])
        for row in scored if row.get("record_type") == "fit"
    }
    expected_runner_counts = {
        family: training_rows_by_family[family] for family in successful_families
    }
    if runner_counts != expected_runner_counts:
        raise RuntimeError(
            f"runner fit counts do not match manifest: {runner_counts} != "
            f"{expected_runner_counts}"
        )
    write_json(calibrations / "manifest.json", manifest)
    scored = _score_rows_with_explicit_calibration_status(scored)
    score_rows = [row for row in scored if row.get("record_type") == "score"]
    fuse_models: dict[str, Any] = {}
    for family in sorted(schemas):
        train = [
            row["labels"] for row in score_rows
            if row["family"] == family and row["split"] == "calibration"
            and _has_temperature(row, fit_temperatures)
        ]
        fuse_model = fit_fuse(train)
        fuse_models[family] = fuse_model.to_dict()
        family_rows = [row for row in score_rows if row["family"] == family]
        if fuse_model.status == "OK":
            predictions = predict_fuse(fuse_model, [row["labels"] for row in family_rows])
            for row, probability in zip(family_rows, predictions, strict=True):
                row["fuse_posterior"] = float(probability)
                row["fuse_status"] = "OK"
        else:
            for row in family_rows:
                row["fuse_posterior"] = None
                row["fuse_status"] = "BLOCKED"
                row["fuse_reason"] = fuse_model.reason
    write_json(calibrations / "fuse_models.json", {
        "provenance": "fuse_style_zero_label_reimplementation",
        "official_implementation": False,
        "fit_temperatures": fit_temperatures,
        "families": fuse_models,
    })
    write_jsonl(output_path, scored)
    return input_path, output_path


def validate_calibration_manifest(
    calibrations: Path,
    *,
    model_name: str,
    level: float,
    instances_path: Path,
) -> dict[str, Any]:
    path = calibrations / "manifest.json"
    if not path.exists():
        raise RuntimeError(f"missing calibration manifest: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    expected_family = _model_config(model_name)["family"]
    if payload.get("model_name") != model_name:
        raise RuntimeError("calibration manifest model-name mismatch")
    if payload.get("base_model_family") != expected_family:
        raise RuntimeError("calibration manifest base-family mismatch")
    if float(payload.get("noise_level")) != float(level):
        raise RuntimeError("calibration manifest noise-level mismatch")
    expected_fit_temperatures = [temperature_policy()["primary_temperature"]]
    if payload.get("fit_temperatures") != expected_fit_temperatures:
        raise RuntimeError("calibration manifest fit-temperature mismatch")
    if payload.get("dataset_revision") != _dataset_revision():
        raise RuntimeError("calibration manifest dataset-revision mismatch")
    if payload.get("instances_sha256") != file_hash(instances_path):
        raise RuntimeError("calibration manifest instance mismatch")
    return payload


def audit_report(
    model_name: str,
    level: float,
    observations_path: Path,
    labels_path: Path,
    instances: list[dict[str, Any]] | None = None,
) -> Path:
    gold = {row["candidate_id"]: bool(row["gold_pass"]) for row in read_jsonl(labels_path)}
    observations = [
        row for row in read_jsonl(observations_path)
        if row.get("record_type") == "observation" and row["split"] == "calibration"
        and row.get("candidate_id") in gold
    ]
    by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in observations:
        by_family[row["family"]].append(row)
    report = []
    pair_report = []
    for family, items in sorted(by_family.items()):
        slots = list(range(len(items[0]["labels"])))
        matrix = np.asarray([
            [row["labels"][slot] for slot in slots] for row in items
        ], dtype=int)
        y = np.asarray([gold[row["candidate_id"]] for row in items], dtype=bool)
        family_effective_rank = effective_rank(matrix)
        conflict = np.logical_and((matrix > 0).any(axis=1), (matrix < 0).any(axis=1))
        pair_values: dict[int, list[dict[str, float]]] = defaultdict(list)
        fires = matrix != 0
        for left in range(matrix.shape[1]):
            for right in range(left + 1, matrix.shape[1]):
                left_fire, right_fire = fires[:, left], fires[:, right]
                union = np.logical_or(left_fire, right_fire).sum()
                jaccard = (
                    float(np.logical_and(left_fire, right_fire).sum() / union)
                    if union else 1.0
                )
                agreement = float((matrix[:, left] == matrix[:, right]).mean())
                left_numeric = left_fire.astype(float)
                right_numeric = right_fire.astype(float)
                left_centered = left_numeric - left_numeric.mean()
                right_centered = right_numeric - right_numeric.mean()
                denominator = float(np.sqrt(
                    np.dot(left_centered, left_centered)
                    * np.dot(right_centered, right_centered)
                ))
                phi = (
                    float(np.dot(left_centered, right_centered) / denominator)
                    if denominator else 0.0
                )
                value = {
                    "agreement": agreement, "jaccard_fire_sets": jaccard, "phi": phi,
                }
                pair_values[left].append(value)
                pair_values[right].append(value)
                pair_report.append({
                    "family": family, "left_slot": left, "right_slot": right, **value,
                })
        family_instance = next(
            (row for row in instances or [] if row["family"] == family), None
        )
        for new_slot, old_slot in enumerate(slots):
            values = matrix[:, new_slot]
            pos = values > 0
            neg = values < 0
            report.append({
                "family": family, "slot": new_slot, "source_slot": old_slot,
                "polarity": (
                    family_instance["weak_rules"][old_slot]["polarity"]
                    if family_instance is not None else None
                ),
                "coverage": float((values != 0).mean()),
                "abstain_rate": float((values == 0).mean()),
                "precision_positive": float(y[pos].mean()) if pos.any() else None,
                "precision_negative": float((~y[neg]).mean()) if neg.any() else None,
                "conflict_rate": float(conflict.mean()),
                "effective_rank": family_effective_rank,
                "mean_pairwise_agreement": float(np.mean([
                    pair["agreement"] for pair in pair_values[new_slot]
                ])) if pair_values[new_slot] else None,
                "max_jaccard_fire_sets": max(
                    (pair["jaccard_fire_sets"] for pair in pair_values[new_slot]),
                    default=None,
                ),
                "max_abs_phi": max(
                    (abs(pair["phi"]) for pair in pair_values[new_slot]),
                    default=None,
                ),
                "gold_valid": int(y.sum()), "gold_invalid": int((~y).sum()),
            })
    output = ARTIFACTS / "reports" / f"{model_name}_noise_{int(level*100):02d}_rule_audit.jsonl"
    write_jsonl(output, report)
    write_jsonl(
        ARTIFACTS / "reports" / f"{model_name}_noise_{int(level*100):02d}_rule_pairs.jsonl",
        pair_report,
    )
    return output


def aggregation_report(model_name: str, level: float, scores_path: Path, labels_path: Path) -> Path:
    config = load_config()
    primary_fit_temperatures = [temperature_policy(config)["primary_temperature"]]
    gold = {row["candidate_id"]: bool(row["gold_pass"]) for row in read_jsonl(labels_path)}
    score_rows = read_jsonl(scores_path)
    all_scores = [
        row for row in score_rows
        if row.get("record_type") == "score" and row.get("candidate_id") in gold
    ]
    rows = [
        row for row in all_scores
        if row["split"] in {"test", "test_official"}
    ]
    by_split_family: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    calibration_by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in all_scores:
        if row["split"] == "calibration" and _has_temperature(row, primary_fit_temperatures):
            calibration_by_family[row["family"]].append(row)
        elif row["split"] in {"test", "test_official"}:
            by_split_family[(row["split"], row["family"])].append(row)
    oracle_by_family: dict[str, Any] = {}
    for family, train in calibration_by_family.items():
        try:
            from sklearn.linear_model import LogisticRegression
            x_train = np.asarray([row["labels"] for row in train], dtype=float)
            y_train = np.asarray([gold[row["candidate_id"]] for row in train], dtype=int)
            oracle = LogisticRegression(C=1.0, max_iter=1000, random_state=0)
            oracle.fit(x_train, y_train)
            oracle_by_family[family] = oracle
        except Exception as exc:
            oracle_by_family[family] = exc
            issue("aggregation.supervised_oracle", exc, family=family, model=model_name)
    output = []
    for split in ["test", "test_official"]:
        split_rows = [row for row in rows if row["split"] == split]
        for family in sorted({family for (row_split, family) in by_split_family if row_split == split}):
            items = by_split_family[(split, family)]
            labels = [gold[row["candidate_id"]] for row in items]
            methods = {
                "prior_only": [.5] * len(items),
                "majority_vote": [majority_probability(row["labels"]) for row in items],
                "equal_signed_sum": [equal_probability(row["labels"]) for row in items],
            }
            posterior_items = [row.get("posterior") for row in items]
            if all(value is not None for value in posterior_items):
                methods["polarity_weak_model"] = [
                    float(value) for value in posterior_items
                ]
            else:
                output.append({
                    "model": model_name, "noise": level, "split": split,
                    "family": family, "aggregator": "polarity_weak_model",
                    "status": "BLOCKED", "reason": "calibration fit failed",
                })
            fuse_items = [row.get("fuse_posterior") for row in items]
            if all(value is not None for value in fuse_items):
                methods["fuse_style_reimplementation"] = [float(value) for value in fuse_items]
            oracle = oracle_by_family.get(family)
            if oracle is not None and not isinstance(oracle, Exception):
                methods["supervised_logistic_oracle"] = oracle.predict_proba(
                    np.asarray([row["labels"] for row in items], dtype=float)
                )[:, 1].tolist()
            else:
                output.append({
                    "model": model_name, "noise": level, "split": split,
                    "family": family, "aggregator": "supervised_logistic_oracle",
                    "status": "BLOCKED", "reason": str(oracle or "missing calibration rows"),
                })
            for method, probabilities in methods.items():
                output.append({
                    "model": model_name, "noise": level, "split": split,
                    "family": family, "aggregator": method,
                    **classification_metrics(
                        labels, probabilities, bins=int(config["ece_bins"])
                    ),
                    "candidates": len(items),
                })
        blocked_families = sorted({
            row["family"] for row in split_rows if row.get("fuse_status") == "BLOCKED"
        })
        if blocked_families:
            output.append({
                "model": model_name, "noise": level, "split": split,
                "family": "__ALL__", "aggregator": "fuse_style_reimplementation",
                "status": "PARTIALLY_BLOCKED", "blocked_families": blocked_families,
                "official_implementation": False,
            })
    path = ARTIFACTS / "reports" / f"{model_name}_noise_{int(level*100):02d}_aggregation.jsonl"
    write_jsonl(path, output)
    return path


def score_pool(model_name: str, level: float, instances_path: Path, candidates: Path) -> Path:
    noise = int(level * 100)
    calibrations = ARTIFACTS / "calibrations" / model_name / f"noise_{noise:02d}"
    validate_calibration_manifest(
        calibrations, model_name=model_name, level=level, instances_path=instances_path
    )
    output = ARTIFACTS / "scores" / f"{model_name}_noise_{noise:02d}_main.jsonl"
    raw_output = ARTIFACTS / "scores" / f"{model_name}_noise_{noise:02d}_main_raw.jsonl"
    observations = observe(
        model_name, candidates, read_jsonl(instances_path), level, stream="main"
    )
    _run_racket(
        f"score_main.{model_name}.{level}",
        [
            "--mode", "score", "--input", str(instances_path),
            "--candidates", str(observations), "--output", str(raw_output),
            "--calibrations-dir", str(calibrations),
        ], raw_output,
    )
    scored = read_jsonl(raw_output)
    failures = [row for row in scored if row.get("record_type") == "score_error"]
    recorded_failures: set[tuple[str, str]] = set()
    for failure in failures:
        key = (
            str(failure.get("family")),
            str(failure.get("message", "calibration unavailable")),
        )
        if key in recorded_failures:
            continue
        recorded_failures.add(key)
        issue(
            "calibration.score",
            RuntimeError(key[1]),
            model=model_name, noise=level, family=failure.get("family"),
            prompt_id=failure.get("prompt_id"),
        )
    expected_scores = sum(
        row.get("status") == "found" and bool(row.get("hard_valid"))
        for row in read_jsonl(candidates)
    )
    if sum(
        row.get("record_type") in {"score", "score_error"}
        and bool(row.get("candidate_id")) for row in scored
    ) != expected_scores:
        raise RuntimeError("proposal scoring cardinality mismatch")
    scored = _score_rows_with_explicit_calibration_status(scored)
    fuse_path = calibrations / "fuse_models.json"
    if not fuse_path.exists():
        raise RuntimeError(f"missing FUSE calibrations: {fuse_path}")
    with fuse_path.open(encoding="utf-8") as handle:
        fuse_payload = json.load(handle)
    for family, payload in fuse_payload["families"].items():
        fuse_model = FuseModel.from_dict(payload)
        family_rows = [
            row for row in scored
            if row.get("record_type") == "score" and row["family"] == family
        ]
        if fuse_model.status == "OK":
            probabilities = predict_fuse(
                fuse_model, [row["labels"] for row in family_rows]
            )
            for row, probability in zip(family_rows, probabilities, strict=True):
                row["fuse_posterior"] = float(probability)
                row["fuse_status"] = "OK"
        else:
            for row in family_rows:
                row["fuse_posterior"] = None
                row["fuse_status"] = "BLOCKED"
                row["fuse_reason"] = fuse_model.reason
    write_jsonl(output, scored)
    return output


def generate_pwsg(model_name: str, level: float, instances_path: Path, proposal_pool: Path) -> Path:
    model = _model_config(model_name)
    config = load_config()
    noise = int(level * 100)
    rows = [
        row for row in read_jsonl(instances_path)
        if row["split"] in {"dev", "test", "test_official"}
    ]
    proposals: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for proposal in read_jsonl(proposal_pool):
        proposals[(proposal["prompt_id"], int(proposal["seed"]))].append(proposal)
    for values in proposals.values():
        values.sort(key=lambda value: int(value["sample_index"]))
    budgets = _budgets(model_name)
    rendered = []
    for row in render_instances(rows, model_name):
        caps = {}
        for seed in config["generation_seeds"]:
            stream = proposals.get((row["id"], int(seed)), [])
            for budget in budgets:
                caps[f"{seed}:{budget}"] = max(1, sum(
                    int(value.get("model_draws", 0)) for value in stream[:budget]
                ))
        rendered.append({**row, "paired_draw_caps": caps})
    rendered_path = ARTIFACTS / "inputs" / f"{model_name}_noise_{noise:02d}_pwsg.jsonl"
    write_jsonl(rendered_path, rendered)
    calibrations = ARTIFACTS / "calibrations" / model_name / f"noise_{noise:02d}"
    validate_calibration_manifest(
        calibrations, model_name=model_name, level=level, instances_path=instances_path
    )
    maximum = max(budgets)
    posterior_policy = config["posterior_policy"]
    piece = ARTIFACTS / "raw" / f"{model_name}_noise_{noise:02d}_pwsg_checkpoints.jsonl"
    _run_racket_sharded(
        f"pwsg.{model_name}.{level}.checkpoints",
        [
            "--mode", "pwsg", "--input", str(rendered_path), "--output", str(piece),
            "--calibrations-dir", str(calibrations), "--model", model["gguf_path"],
            "--temperature", str(temperature_policy(config)["primary_temperature"]),
            "--seeds", ",".join(map(str, config["generation_seeds"])),
            "--max-attempts", str(config["hard_max_attempts"]),
            "--attempt-checkpoints", ",".join(map(str, budgets)),
            "--good-multiplier", str(posterior_policy["good_multiplier"]),
            "--bad-multiplier", str(posterior_policy["bad_multiplier"]),
            "--deadline-ms", str(config["hard_deadline_ms"]),
        ], piece, records_per_input=len(config["generation_seeds"]) * len(budgets),
    )
    enriched = []
    recorded_failures: set[tuple[str, str]] = set()
    for row in read_jsonl(piece):
        budget = int(row.get("checkpoint_budget", maximum))
        if row.get("record_type") == "pwsg_error":
            key = (
                str(row.get("family")),
                str(row.get("message", "calibration unavailable")),
            )
            if key not in recorded_failures:
                recorded_failures.add(key)
                issue(
                    "calibration.pwsg", RuntimeError(key[1]),
                    model=model_name, noise=level, family=row.get("family"),
                )
            enriched.append({
                **row, "model_family": model["family"], "noise": level,
                "budget": budget,
            })
            continue
        if row.get("record_type") != "pwsg":
            raise RuntimeError(f"unexpected PWSG record at budget {budget}: {row}")
        generation_id = stable_hash({
            "method": "exact_pwsg", "prompt_id": row.get("prompt_id"),
            "seed": row.get("seed"), "text": row.get("text"),
            "noise": level, "model": model["family"], "budget": budget,
        })
        enriched.append({
            **row, "generation_id": generation_id,
            "model_family": model["family"], "noise": level, "budget": budget,
        })
    output = ARTIFACTS / "raw" / f"{model_name}_noise_{noise:02d}_pwsg.jsonl"
    write_jsonl(output, enriched)
    return output


def evaluate_generations(instances_path: Path, generations_path: Path, output_path: Path) -> None:
    instances = {row["id"]: row for row in read_jsonl(instances_path)}
    generations = [
        row for row in read_jsonl(generations_path)
        if row.get("record_type") == "pwsg"
    ]
    workers = int(load_config().get("runtime", {}).get("evaluator_workers", os.cpu_count() or 1))
    try:
        passed_values = official_check_many(
            [(instances[row["prompt_id"]], row.get("text", "")) for row in generations],
            workers=max(1, workers),
        )
    except Exception as exc:
        issue("official_generation_evaluation", exc, generations=len(generations))
        raise
    labels = [{
        "generation_id": generation["generation_id"],
        "prompt_id": generation["prompt_id"],
        "gold_pass": passed,
    } for generation, passed in zip(generations, passed_values, strict=True)]
    if len(labels) != len(generations):
        raise RuntimeError("official generation evaluation cardinality mismatch")
    write_jsonl(output_path, labels)


def _operational_threshold(rows: list[dict[str, Any]], target: float) -> float:
    found = sorted(
        (row for row in rows if row["outcome"] != "NOT_FOUND"),
        key=lambda row: float(row["confidence"]),
        reverse=True,
    )
    best = math.inf
    best_coverage = -1.0
    returned = wrong = index = 0
    while index < len(found):
        threshold = float(found[index]["confidence"])
        next_index = index
        while (
            next_index < len(found)
            and float(found[next_index]["confidence"]) == threshold
        ):
            returned += 1
            wrong += found[next_index]["outcome"] == "FOUND_WRONG"
            next_index += 1
        risk = wrong / returned
        coverage = returned / len(rows)
        if risk <= target and (coverage > best_coverage or (coverage == best_coverage and threshold > best)):
            best, best_coverage = threshold, coverage
        index = next_index
    return best


def generation_report(
    model_name: str,
    level: float,
    proposal_pool: Path,
    proposal_scores: Path,
    proposal_labels: Path,
    pwsg_path: Path,
    pwsg_labels: Path,
    instance_rows: list[dict[str, Any]] | None = None,
    evaluation_splits: tuple[str, ...] = ("test", "test_official"),
) -> Path:
    started = time.perf_counter()
    config = load_config()
    score_by_id = {
        row["candidate_id"]: row for row in read_jsonl(proposal_scores)
        if row.get("record_type") == "score"
    }
    gold_by_id = {row["candidate_id"]: bool(row["gold_pass"]) for row in read_jsonl(proposal_labels)}
    proposals: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for row in read_jsonl(proposal_pool):
        score = score_by_id.get(row["candidate_id"])
        enriched = {**row, "gold_pass": gold_by_id.get(row["candidate_id"], False)}
        if score is not None:
            enriched.update(score)
        proposals[(row["prompt_id"], int(row["seed"]))].append(enriched)
    for values in proposals.values():
        values.sort(key=lambda row: int(row["sample_index"]))

    instance_by_id = {row["id"]: row for row in (instance_rows or all_instances())}
    outcomes = []
    expected_grid = [
        (row["id"], int(seed))
        for row in instance_by_id.values()
        if row["split"] in {"dev", "test", "test_official"}
        for seed in config["generation_seeds"]
    ]
    for prompt_id, seed in sorted(expected_grid):
        stream = proposals.get((prompt_id, seed), [])
        for budget in _budgets(model_name):
            attempted = stream[:budget]
            candidates = [
                row for row in attempted
                if row.get("status") == "found" and row.get("hard_valid")
                and row.get("record_type") == "score"
            ]
            total_content_tokens = sum(
                int(row.get("proposed_tokens", 0))
                for row in attempted
            )
            total_model_draws = sum(
                int(row.get("model_draws", 0))
                for row in attempted
            )
            total_latency = sum(float(row.get("latency_ms", 0.0)) for row in attempted)
            first = attempted[0] if attempted else None
            first_found = (
                first if first is not None
                and first.get("status") == "found" and first.get("hard_valid")
                and first.get("record_type") == "score" else None
            )
            methods = {
                "hard_only_cars": first_found,
                "lm_best_of_b": max(candidates, key=lambda row: float(row.get("lm_logprob") or -math.inf)) if candidates else None,
                "equal_score_best_of_b": max(candidates, key=lambda row: (sum(row["labels"]), float(row.get("lm_logprob") or -math.inf))) if candidates else None,
            }
            posterior_candidates = [
                row for row in candidates if row.get("posterior") is not None
            ]
            methods["posterior_best_of_b"] = (
                max(
                    posterior_candidates,
                    key=lambda row: (
                        float(row["posterior"]),
                        float(row.get("lm_logprob") or -math.inf),
                    ),
                ) if posterior_candidates else None
            )
            fuse_candidates = [row for row in candidates if row.get("fuse_posterior") is not None]
            methods["fuse_style_best_of_b"] = (
                max(
                    fuse_candidates,
                    key=lambda row: (
                        float(row["fuse_posterior"]),
                        float(row.get("lm_logprob") or -math.inf),
                    ),
                ) if fuse_candidates else None
            )
            oracle = next((row for row in candidates if row["gold_pass"]), None)
            methods["gold_oracle"] = oracle
            for method, selected in methods.items():
                if selected is None:
                    hard_only = method == "hard_only_cars"
                    calibration_errors = [
                        row.get("calibration_error", "calibration unavailable")
                        for row in attempted
                        if row.get("calibration_status") == "ERROR"
                    ]
                    outcomes.append({
                        "model": model_name, "noise": level, "prompt_id": prompt_id,
                        "family": instance_by_id[prompt_id]["family"],
                        "split": instance_by_id[prompt_id]["split"],
                        "seed": seed, "budget": budget, "method": method,
                        "outcome": "NOT_FOUND", "confidence": 0.0,
                        "content_tokens": (
                            int(first.get("proposed_tokens", 0))
                            if hard_only and first is not None else total_content_tokens
                        ),
                        "model_draws": (
                            int(first.get("model_draws", 0))
                            if hard_only and first is not None else total_model_draws
                        ),
                        "proposals": min(1, len(attempted)) if hard_only else len(attempted),
                        "latency_ms": (
                            float(first.get("latency_ms", 0.0))
                            if hard_only and first is not None else total_latency
                        ),
                        **({
                            "calibration_status": "ERROR",
                            "calibration_error": calibration_errors[0],
                        } if method == "posterior_best_of_b" and calibration_errors else {}),
                    })
                    continue
                if method.startswith("posterior"):
                    confidence = float(selected["posterior"])
                elif method.startswith("fuse_style"):
                    confidence = float(selected["fuse_posterior"])
                elif method.startswith("equal"):
                    confidence = equal_probability(selected["labels"])
                elif method == "gold_oracle":
                    confidence = 1.0
                else:
                    confidence = float(selected.get("lm_logprob") or -math.inf) / max(1, int(selected["token_count"]))
                outcomes.append({
                    "model": model_name, "noise": level, "prompt_id": prompt_id,
                    "family": instance_by_id[prompt_id]["family"],
                    "split": instance_by_id[prompt_id]["split"],
                    "seed": seed, "budget": budget, "method": method,
                    "outcome": "FOUND_OK" if selected["gold_pass"] else "FOUND_WRONG",
                    "confidence": confidence,
                    "content_tokens": (
                        int(attempted[0].get("proposed_tokens", 0))
                        if method == "hard_only_cars" else total_content_tokens
                    ),
                    "model_draws": (
                        int(attempted[0].get("model_draws", 0))
                        if method == "hard_only_cars" else total_model_draws
                    ),
                    "proposals": 1 if method == "hard_only_cars" else len(attempted),
                    "latency_ms": (
                        float(attempted[0].get("latency_ms", 0.0))
                        if method == "hard_only_cars" else total_latency
                    ),
                })

    pwsg_gold = {row["generation_id"]: bool(row["gold_pass"]) for row in read_jsonl(pwsg_labels)}
    for row in read_jsonl(pwsg_path):
        if row.get("record_type") == "pwsg_error":
            outcomes.append({
                "model": model_name, "noise": level,
                "prompt_id": row["prompt_id"], "family": row["family"],
                "split": row["split"], "seed": row["seed"],
                "budget": int(row["budget"]), "method": "exact_pwsg",
                "outcome": "NOT_FOUND", "confidence": 0.0,
                "content_tokens": 0, "model_draws": 0, "proposals": 0,
                "latency_ms": 0.0, "calibration_status": "ERROR",
                "calibration_error": row.get("message"),
            })
            continue
        if row.get("record_type") != "pwsg":
            continue
        attempts = int(row["attempts"])
        found = row["status"] == "found"
        outcome = (
            "FOUND_OK" if found and pwsg_gold.get(row["generation_id"], False)
            else "FOUND_WRONG" if found else "NOT_FOUND"
        )
        outcomes.append({
            "model": model_name, "noise": level, "prompt_id": row["prompt_id"],
            "family": row["family"], "split": row["split"], "seed": row["seed"],
            "budget": int(row["budget"]), "method": "exact_pwsg", "outcome": outcome,
            "confidence": float(row.get("posterior") or 0.0),
            "content_tokens": int(row["proposed_tokens"]),
            "model_draws": int(row["model_draws"]),
            "proposals": attempts, "latency_ms": float(row["latency_ms"]),
        })

    summaries = []
    methods = sorted({row["method"] for row in outcomes})
    thresholds = []
    operational_thresholds: dict[tuple[str, int], float] = {}
    for budget in _budgets(model_name):
        for method in methods:
            dev = [
                row for row in outcomes
                if row["budget"] == budget and row["method"] == method
                and row["split"] == "dev"
            ]
            tau = (
                _operational_threshold(dev, config["operational_risk"])
                if dev and method != "gold_oracle" else -math.inf
            )
            operational_thresholds[(method, budget)] = tau
            selected = [
                {**row, "outcome": "NOT_FOUND"}
                if row["outcome"] != "NOT_FOUND" and float(row["confidence"]) < tau
                else row for row in dev
            ]
            thresholds.append({
                "run_id": ARTIFACTS.name, "model": model_name, "noise": level,
                "method": method, "budget": budget, "source_split": "dev",
                "target_risk": config["operational_risk"],
                "global_across_families": True,
                "threshold": tau if math.isfinite(tau) else None,
                "accept_if": (
                    "confidence_gte" if math.isfinite(tau)
                    else "never" if tau > 0 else "always"
                ),
                "dev_rows": len(dev), "dev_metrics": operating_metrics(selected),
                "dev_sha256": stable_hash(dev), "config_sha256": stable_hash(config),
            })
    write_jsonl_once(
        ARTIFACTS / "thresholds" / f"{model_name}_noise_{int(level*100):02d}.jsonl",
        thresholds,
    )
    strict_methods = {"posterior_best_of_b", "fuse_style_best_of_b", "exact_pwsg"}
    for budget in _budgets(model_name):
        for method in methods:
            threshold = operational_thresholds[(method, budget)]
            for split in evaluation_splits:
                rows = [
                    dict(row) for row in outcomes
                    if row["budget"] == budget and row["method"] == method and row["split"] == split
                ]
                policies = [("raw", -math.inf), ("operational", threshold)]
                if method in strict_methods:
                    policies.insert(1, ("strict", config["strict_tau"]))
                for policy, tau in policies:
                    policy_rows = []
                    for row in rows:
                        if row["outcome"] != "NOT_FOUND" and float(row["confidence"]) < tau:
                            policy_rows.append({**row, "outcome": "NOT_FOUND"})
                        else:
                            policy_rows.append(row)
                    def summarize(items: list[dict[str, Any]]) -> dict[str, Any]:
                        curve = selective_curve(items)
                        point = operating_metrics(items)
                        found_ok = int(point["found_ok"])
                        return {
                            **point, "max_coverage": max_coverage(curve),
                            "prompts_x_seeds": len(items),
                            "found_ok_rate": point["solve_rate"],
                            "found_wrong_rate": int(point["found_wrong"]) / len(items) if items else 0.0,
                            "not_found_rate": int(point["not_found"]) / len(items) if items else 0.0,
                            "mean_model_tokens": (
                                float(np.mean([row["model_draws"] for row in items]))
                                if items else 0.0
                            ),
                            "mean_content_tokens": (
                                float(np.mean([row["content_tokens"] for row in items]))
                                if items else 0.0
                            ),
                            "tokens_per_ok": (
                                sum(row["model_draws"] for row in items) / found_ok
                                if found_ok else None
                            ),
                        }

                    base = {
                        "model": model_name, "noise": level, "split": split,
                        "budget": budget, "method": method, "policy": policy,
                        "threshold": tau if math.isfinite(tau) else None,
                    }
                    micro = summarize(policy_rows)
                    summaries.append({**base, "aggregation": "micro", "family": "__ALL__", **micro})
                    family_summaries = []
                    for family in sorted({row["family"] for row in policy_rows}):
                        value = summarize([row for row in policy_rows if row["family"] == family])
                        family_summaries.append(value)
                        summaries.append({
                            **base, "aggregation": "family", "family": family, **value,
                        })
                    macro_metrics = [
                        "solve_rate", "coverage",
                        "found_ok_rate", "found_wrong_rate", "not_found_rate",
                        "max_coverage", "mean_model_tokens", "mean_content_tokens",
                    ]
                    summaries.append({
                        **base, "aggregation": "macro", "family": "__MACRO__",
                        **{
                            key: float(np.mean([value[key] for value in family_summaries]))
                            for key in macro_metrics
                        },
                        "risk": (
                            float(np.mean([
                                value["risk"] for value in family_summaries
                                if value["risk"] is not None
                            ]))
                            if any(value["risk"] is not None for value in family_summaries)
                            else None
                        ),
                        "found_ok": micro["found_ok"], "found_wrong": micro["found_wrong"],
                        "not_found": micro["not_found"],
                        "prompts_x_seeds": micro["prompts_x_seeds"],
                        "tokens_per_ok": (
                            float(np.mean([
                                value["tokens_per_ok"] for value in family_summaries
                                if value["tokens_per_ok"] is not None
                            ]))
                            if any(value["tokens_per_ok"] is not None for value in family_summaries)
                            else None
                        ),
                    })
    raw_path = ARTIFACTS / "results" / f"{model_name}_noise_{int(level*100):02d}_generation_raw.jsonl"
    summary_path = ARTIFACTS / "results" / f"{model_name}_noise_{int(level*100):02d}_generation_summary.jsonl"
    write_jsonl(raw_path, outcomes)
    write_jsonl(summary_path, summaries)
    wall_seconds = time.perf_counter() - started
    write_json(
        ARTIFACTS / "runtime"
        / f"{model_name}_noise_{int(level*100):02d}_selection.json",
        {
            "stage": f"selection.{model_name}.{level}",
            "category": "selection_and_reporting",
            "rows": len(outcomes),
            "wall_seconds": wall_seconds,
            "rows_per_second": len(outcomes) / wall_seconds if wall_seconds else 0.0,
            "workers": 1,
        },
    )
    return summary_path
