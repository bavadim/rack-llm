from __future__ import annotations

import importlib.util
import os
import shutil
from pathlib import Path

from .common import ARTIFACTS, CACHE, DATA, REPO, issue, load_config, write_json


def preflight() -> dict:
    config = load_config()
    checks = {
        "racket": shutil.which("racket") is not None,
        "native_llama": (REPO / "native" / "llama" / "build" / "librackllm_llama.so").exists(),
        "native_regex": (REPO / "native" / "regex" / "build" / "librackllm_pcre2.so").exists(),
        "qwen_hf": Path(config["main_model"]["hf_path"]).exists(),
        "qwen_gguf": Path(config["main_model"]["gguf_path"]).exists(),
        "phi_hf": Path(config["replication_model"]["hf_path"]).exists(),
        "phi_gguf": Path(config["replication_model"]["gguf_path"]).exists(),
        "ifbench": (CACHE / "ifbench" / "instructions_registry.py").exists(),
        "ifbench_evaluator": all(
            (CACHE / "ifbench" / name).is_file()
            for name in ["evaluation_lib.py", "instructions.py", "instructions_util.py"]
        ),
        "nltk_data": all(
            (CACHE / "ifbench" / ".nltk_data" / relative).is_dir()
            for relative in ["tokenizers/punkt", "tokenizers/punkt_tab", "corpora/stopwords",
                             "taggers/averaged_perceptron_tagger_eng"]
        ),
        "dataset_manifest": (DATA / "manifest.json").exists(),
        "sklearn": importlib.util.find_spec("sklearn") is not None,
        "matplotlib": importlib.util.find_spec("matplotlib") is not None,
        "guidance": importlib.util.find_spec("guidance") is not None,
        "outlines": importlib.util.find_spec("outlines") is not None,
        "nltk": importlib.util.find_spec("nltk") is not None,
        "emoji": importlib.util.find_spec("emoji") is not None,
        "syllapy": importlib.util.find_spec("syllapy") is not None,
        "fuse_reimplementation": importlib.util.find_spec("scipy") is not None,
    }
    for name, ok in checks.items():
        if not ok:
            issue("preflight", f"missing requirement: {name}", requirement=name)
    result = {
        "full_ok": all(checks.values()),
        "checks": checks,
        "warnings": [],
        "runtime": {
            **config.get("runtime", {}),
            "host_logical_cpus": os.cpu_count(),
            "planned_regex_threads": (
                int(config.get("runtime", {}).get("generation_workers", 1))
                * int(config.get("runtime", {}).get("regex_threads", 1))
            ),
        },
    }
    write_json(ARTIFACTS / "preflight.json", result)
    return result
