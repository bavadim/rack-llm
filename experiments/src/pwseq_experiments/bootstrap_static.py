from __future__ import annotations

import subprocess
import sys

from .common import CACHE, load_config


def bootstrap_static() -> None:
    config = load_config()
    target = CACHE / "ifbench"
    if not target.exists():
        subprocess.run(["git", "clone", config["ifbench"]["repository"], str(target)], check=True)
    subprocess.run(["git", "checkout", "--detach", config["ifbench"]["commit"]], cwd=target, check=True)
    nltk_data = target / ".nltk_data"
    subprocess.run([
        sys.executable, "-c",
        "import nltk,sys; names=('punkt','punkt_tab','stopwords','averaged_perceptron_tagger_eng');"
        "raise SystemExit(0 if all(nltk.download(x,download_dir=sys.argv[1],quiet=True) for x in names) else 1)",
        str(nltk_data),
    ], check=True)
