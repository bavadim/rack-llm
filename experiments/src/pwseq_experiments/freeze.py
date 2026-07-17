from __future__ import annotations

from datetime import datetime, timezone

from pathlib import Path
import subprocess

from .common import ACTIVE_RUN_FILE, ARTIFACT_ROOT, CACHE, DATA, EXPERIMENTS, REPO, CONFIG_PATH, file_hash, load_config, stable_hash, write_json


def freeze() -> dict:
    dirty = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"], cwd=REPO, text=True
    )
    if dirty.strip():
        raise RuntimeError("cannot freeze a dirty Git worktree")
    files = [
        CONFIG_PATH, EXPERIMENTS / "requirements.txt",
        EXPERIMENTS / "Makefile", EXPERIMENTS / "README.md",
    ]
    files.extend(sorted(DATA.glob("*.jsonl")))
    files.append(DATA / "manifest.json")
    files.extend(sorted((EXPERIMENTS / "src").rglob("*.py")))
    files.extend(sorted((EXPERIMENTS / "racket").glob("*.rkt")))
    files.extend(sorted((EXPERIMENTS / "tests").glob("test_*.py")))
    files.extend(sorted(REPO.glob("*.rkt")))
    files.extend(sorted((REPO / "private").glob("*.rkt")))
    files.extend(sorted((REPO / "tests").rglob("*.rkt")))
    files.extend(sorted(
        path for path in (REPO / "native").rglob("*")
        if path.is_file() and (path.suffix in {".c", ".h"} or path.name == "Makefile")
    ))
    config = load_config()
    required = [
        REPO / "native" / "llama" / "build" / "librackllm_llama.so",
        REPO / "native" / "regex" / "build" / "librackllm_pcre2.so",
        CACHE / "ifbench" / "instructions.py",
        CACHE / "ifbench" / "instructions_registry.py",
        CACHE / "ifbench" / "evaluation_lib.py",
        CACHE / "ifbench" / "instructions_util.py",
    ]
    external_files = list(required)
    required_directories = [
        CACHE / "ifbench" / ".nltk_data" / "tokenizers" / "punkt",
        CACHE / "ifbench" / ".nltk_data" / "tokenizers" / "punkt_tab",
        CACHE / "ifbench" / ".nltk_data" / "corpora" / "stopwords",
        CACHE / "ifbench" / ".nltk_data" / "taggers" / "averaged_perceptron_tagger_eng",
    ]
    external_files.extend(sorted(
        path for path in (CACHE / "ifbench" / ".nltk_data").rglob("*") if path.is_file()
    ))
    for model_key in ["main_model", "replication_model"]:
        model = config[model_key]
        gguf = Path(model["gguf_path"])
        required.append(gguf)
        external_files.append(gguf)
        hf_root = Path(model["hf_path"])
        for pattern in ["tokenizer*", "vocab*", "merges*", "chat_template*", "config.json"]:
            external_files.extend(sorted(hf_root.glob(pattern)))
    missing = [str(path) for path in required if not path.is_file()]
    missing.extend(str(path) for path in required_directories if not path.is_dir())
    if missing:
        raise RuntimeError(f"cannot freeze with missing external inputs: {missing}")
    llama_root = Path(config["native"]["llama_cpp_dir"])
    manifest = {
        "frozen_at_utc": datetime.now(timezone.utc).isoformat(),
        "git_revision": __import__("subprocess").check_output(
            ["git", "rev-parse", "HEAD"], cwd=REPO, text=True
        ).strip(),
        "files": {
            str(path.relative_to(REPO)): file_hash(path)
            for path in files if path.exists()
        },
        "external_files": {
            str(path): file_hash(path) for path in external_files if path.is_file()
        },
        "llama_cpp_revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=llama_root, text=True
        ).strip(),
        "ifbench_revision": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=CACHE / "ifbench", text=True
        ).strip(),
    }
    run_id = stable_hash({key: value for key, value in manifest.items() if key != "frozen_at_utc"})[:16]
    manifest["run_id"] = run_id
    run_root = ARTIFACT_ROOT / run_id
    if run_root.exists():
        raise RuntimeError(f"frozen run already exists: {run_id}")
    write_json(run_root / "frozen_manifest.json", manifest)
    ACTIVE_RUN_FILE.parent.mkdir(parents=True, exist_ok=True)
    ACTIVE_RUN_FILE.write_text(run_id + "\n", encoding="utf-8")
    return manifest
