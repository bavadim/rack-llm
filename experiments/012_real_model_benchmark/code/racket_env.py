#!/usr/bin/env python3
"""Racket subprocess environment for running this checkout without package install."""

from __future__ import annotations

import os
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]


def racket_env() -> dict[str, str]:
    env = os.environ.copy()
    existing = env.get("PLTCOLLECTS", "")
    checkout_parent = str(REPO_ROOT.parent)
    env["PLTCOLLECTS"] = (
        checkout_parent + os.pathsep + existing
        if existing
        else checkout_parent + os.pathsep
    )
    return env
