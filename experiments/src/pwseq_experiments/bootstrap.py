from __future__ import annotations

import os
import sys
from pathlib import Path

from .common import ARTIFACTS, CACHE, REPO, issue, load_config, run_once, write_json


def bootstrap() -> dict:
    config = load_config()
    status: dict[str, object] = {}
    native = config["native"]
    llama_root = Path(os.environ.get("LLAMA_CPP_DIR", native["llama_cpp_dir"]))
    status["native_regex"] = run_once(
        "bootstrap.native_regex", ["make", "native-regex"], cwd=REPO
    )
    checkout_ok = (
        llama_root.exists()
        and run_once(
            "bootstrap.llama_checkout",
            ["git", "diff", "--quiet", native["llama_cpp_commit"], "--"],
            cwd=llama_root,
        )
    )
    status["llama_checkout"] = checkout_ok
    status["native_llama"] = bool(checkout_ok) and run_once(
        "bootstrap.native_llama",
        ["make", "native-llama", f"LLAMA_CPP_DIR={llama_root}"],
        cwd=REPO,
    )

    python = Path(sys.executable)
    status["dependencies"] = True

    ifbench = CACHE / "ifbench"
    if not ifbench.exists():
        status["ifbench_clone"] = run_once(
            "bootstrap.ifbench",
            ["git", "clone", config["ifbench"]["repository"], str(ifbench)],
        )
    else:
        status["ifbench_clone"] = True
    if ifbench.exists():
        status["ifbench_checkout"] = run_once(
            "bootstrap.ifbench_checkout",
            ["git", "checkout", "--detach", config["ifbench"]["commit"]],
            cwd=ifbench,
        )
        nltk_data = ifbench / ".nltk_data"
        status["nltk_resources"] = run_once(
            "bootstrap.nltk_resources",
            [
                str(python), "-c",
                "import nltk,sys; "
                "ok=all(nltk.download(x,download_dir=sys.argv[1],quiet=True) "
                "for x in ('punkt','punkt_tab','stopwords','averaged_perceptron_tagger_eng')); "
                "raise SystemExit(0 if ok else 1)",
                str(nltk_data),
            ],
        )

    replication = config["replication_model"]
    phi_hf = Path(replication["hf_path"])
    if not phi_hf.exists():
        status["phi_hf"] = run_once(
            "bootstrap.phi_hf",
            [
                str(python), "-c",
                (
                    "from huggingface_hub import snapshot_download;"
                    "import sys;"
                    "snapshot_download(repo_id=sys.argv[1],revision=sys.argv[2],"
                    "local_dir=sys.argv[3])"
                ),
                replication["repository"], replication["revision"], str(phi_hf),
            ],
        )
    else:
        status["phi_hf"] = True

    phi_gguf = Path(config["replication_model"]["gguf_path"])
    if not phi_gguf.exists():
        phi_gguf.parent.mkdir(parents=True, exist_ok=True)
        converted = phi_gguf.parent / "Phi-4-mini-instruct-F16.gguf"
        quantize = llama_root / "build-rack-llm" / "bin" / "llama-quantize"
        if not quantize.exists():
            run_once(
                "bootstrap.phi_quantizer",
                ["cmake", "--build", str(llama_root / "build-rack-llm"),
                 "--target", "llama-quantize", "-j", "4"],
            )
        ok_convert = run_once(
            "bootstrap.phi_convert",
            [str(python), str(llama_root / "convert_hf_to_gguf.py"), str(phi_hf), "--outfile", str(converted), "--outtype", "f16"],
        )
        if ok_convert and quantize.exists():
            status["phi_gguf"] = run_once(
                "bootstrap.phi_quantize",
                [str(quantize), str(converted), str(phi_gguf), "Q4_K_M"],
            )
        else:
            status["phi_gguf"] = False
            issue("bootstrap.phi_quantize", "conversion or llama-quantize unavailable")
    else:
        status["phi_gguf"] = True

    status["fuse_reimplementation"] = True
    write_json(ARTIFACTS / "bootstrap_status.json", status)
    failed = [name for name, ok in status.items() if not ok]
    if failed:
        raise RuntimeError(f"bootstrap failed requirements: {', '.join(failed)}")
    return status
