#!/usr/bin/env python3
"""Set up and verify the native real Qwen backend for Experiment 012.

The script is intentionally explicit: dependency installation and model download
only happen when requested with flags. A plain run performs checks and writes
backend metadata if the environment is already ready.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import venv
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
RESULTS_DIR = EXPERIMENT_DIR / "results"
ROOT_DATA_DIR = REPO_ROOT / "data"
DEFAULT_VENV = REPO_ROOT / ".venv-realbench"
DEFAULT_MODEL_ID = "Qwen/Qwen3.5-4B"
DEFAULT_MODEL_DIR = Path("/mnt/storage/models/qwen/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf")
PYTORCH_CUDA_INDEX = "https://download.pytorch.org/whl/cu128"

BASE_PACKAGES = [
    "numpy",
    "transformers",
    "accelerate",
    "huggingface_hub",
    "guidance",
    "outlines",
    "scipy",
    "pandas",
    "nltk==3.9.4",
    "emoji==2.15.0",
    "syllapy==0.7.2",
]

METADATA_NAME = "backend_metadata.json"
ROOT_METADATA_NAME = "012_backend_metadata.json"
MISSING_NAME = "MISSING_BACKEND.md"


@dataclass(frozen=True)
class CheckResult:
    ok: bool
    missing: list[str]
    metadata: dict[str, Any]


def venv_python(venv_dir: Path) -> Path:
    return venv_dir / "bin" / "python"


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> None:
    subprocess.run(cmd, cwd=REPO_ROOT, env=env, check=True)


def ensure_venv(venv_dir: Path) -> None:
    if not venv_python(venv_dir).exists():
        venv.EnvBuilder(with_pip=True).create(venv_dir)


def install_packages(venv_dir: Path) -> None:
    py = str(venv_python(venv_dir))
    run([py, "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
    run([py, "-m", "pip", "install", "--index-url", PYTORCH_CUDA_INDEX, "torch"])
    run([py, "-m", "pip", "install", *BASE_PACKAGES])


def download_model(venv_dir: Path, model_id: str, model_dir: Path) -> None:
    code = """
from huggingface_hub import snapshot_download
import sys
snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], local_dir_use_symlinks=False)
"""
    model_dir.parent.mkdir(parents=True, exist_ok=True)
    run([str(venv_python(venv_dir)), "-c", code, model_id, str(model_dir)])


def collect_package_versions(py: Path) -> dict[str, str | None]:
    code = """
import importlib.metadata as md, json
pkgs = ["numpy", "torch", "transformers", "accelerate", "huggingface_hub", "guidance", "outlines", "scipy", "pandas", "nltk", "emoji", "syllapy"]
out = {}
for pkg in pkgs:
    try:
        out[pkg] = md.version(pkg)
    except md.PackageNotFoundError:
        out[pkg] = None
print(json.dumps(out, sort_keys=True))
"""
    completed = subprocess.run([str(py), "-c", code], text=True, capture_output=True, check=True)
    return json.loads(completed.stdout)


def smoke_model(model_path: Path) -> dict[str, Any]:
    code = """
(begin
  (require json rack-llm rack-llm/model-llama-cpp)
  (define model
    (llama-cpp-model #:model-path (vector-ref (current-command-line-arguments) 0)
                     #:context-size 128
                     #:threads 1
                     #:gpu-layers -1))
  (define result
    (generate model "Answer yes or no:" (choice (list (lit " yes") (lit " no")))
              #:max-tokens 2
              #:seed 0))
  (define payload
    (hash 'backend "llama.cpp-native"
          'generation_status (symbol->string (generation-result-status result))
          'generated_tokens (generation-result-generated-tokens result)
          'generated_text (generation-result-text result)
          'model_path (vector-ref (current-command-line-arguments) 0)))
  (model-close! model)
  (write-json payload)
  (newline))
"""
    completed = subprocess.run(
        ["racket", "-e", code, str(model_path)],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(completed.stdout)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def model_metadata(model_dir: Path) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "path": str(model_dir),
        "exists": model_dir.exists(),
        "files": {},
    }
    if model_dir.is_file():
        metadata["files"][model_dir.name] = {"sha256": sha256_file(model_dir), "bytes": model_dir.stat().st_size}
    elif model_dir.is_dir():
        for name in ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json"]:
            path = model_dir / name
            if path.exists():
                metadata["files"][name] = {"sha256": sha256_file(path), "bytes": path.stat().st_size}
    return metadata


def check_backend(venv_dir: Path, model_dir: Path, *, run_smoke: bool) -> CheckResult:
    py = venv_python(venv_dir)
    missing: list[str] = []
    metadata: dict[str, Any] = {
        "backend": "llama.cpp-native",
        "python": platform.python_version(),
        "venv": str(venv_dir),
        "model": model_metadata(model_dir),
        "packages": {},
    }
    if not model_dir.exists():
        missing.append(f"GGUF model is missing: {model_dir}")
    if py.exists():
        try:
            metadata["packages"] = collect_package_versions(py)
        except subprocess.CalledProcessError as error:
            missing.append(f"cannot collect package versions: {error}")
    else:
        metadata["packages"] = {"venv": None}
    if missing:
        return CheckResult(False, missing, metadata)
    if run_smoke:
        try:
            metadata["smoke"] = smoke_model(model_dir)
            if metadata["smoke"].get("generation_status") != "found":
                missing.append("native llama.cpp smoke generation did not return found")
        except subprocess.CalledProcessError as error:
            missing.append("native llama.cpp smoke failed: " + (error.stderr[-2000:] if error.stderr else str(error)))
    return CheckResult(not missing, missing, metadata)


def write_outputs(result: CheckResult, output_dirs: list[Path]) -> None:
    for output_dir in output_dirs:
        output_dir.mkdir(parents=True, exist_ok=True)
        metadata_name = ROOT_METADATA_NAME if output_dir == ROOT_DATA_DIR else METADATA_NAME
        if result.ok:
            (output_dir / metadata_name).write_text(
                json.dumps(result.metadata, indent=2, sort_keys=True),
                encoding="utf-8",
            )
            missing = output_dir / MISSING_NAME
            if missing.exists():
                missing.unlink()
        else:
            (output_dir / MISSING_NAME).write_text(missing_markdown(result), encoding="utf-8")


def missing_markdown(result: CheckResult) -> str:
    lines = [
        "# Missing Real Qwen Backend",
        "",
        "Task 012 is fail-closed. Benchmark metrics must not be packaged until",
        "the native Qwen GGUF backend is ready.",
        "",
        "## Missing Requirements",
        "",
    ]
    lines.extend(f"- {item}" for item in result.missing)
    lines.extend(
        [
            "",
            "## Metadata",
            "",
            "```json",
            json.dumps(result.metadata, indent=2, sort_keys=True),
            "```",
            "",
        ]
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--venv", type=Path, default=DEFAULT_VENV)
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--model-dir", type=Path, default=Path(os.environ.get("RACK_LLM_GGUF_MODEL", str(DEFAULT_MODEL_DIR))))
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--experiment-only", action="store_true")
    parser.add_argument("--no-write", action="store_true", help="check only; do not write metadata or MISSING_BACKEND artifacts")
    args = parser.parse_args(argv)

    if args.install or args.download:
        ensure_venv(args.venv)
    if args.install:
        install_packages(args.venv)
    if args.download:
        download_model(args.venv, args.model_id, args.model_dir)

    result = check_backend(args.venv, args.model_dir, run_smoke=args.smoke)
    if not args.no_write:
        output_dirs = [RESULTS_DIR]
        if not args.experiment_only:
            output_dirs.append(ROOT_DATA_DIR)
        write_outputs(result, output_dirs)
    print(json.dumps({"ok": result.ok, "missing": result.missing, "metadata": result.metadata}, sort_keys=True))
    return 0 if result.ok else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
