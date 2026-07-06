#!/usr/bin/env python3
"""Compatibility import for the Experiment 007 soft-rule builder."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any


def _load_impl() -> ModuleType:
    path = Path(__file__).resolve().parents[1] / "007_soft_rules" / "code" / "soft_rules.py"
    spec = importlib.util.spec_from_file_location("_rack_llm_soft_rules_impl", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load soft_rules implementation from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_impl = _load_impl()

RuleSpec: Any = _impl.RuleSpec
build_soft_rules: Any = _impl.build_soft_rules

__all__ = ["RuleSpec", "build_soft_rules"]
