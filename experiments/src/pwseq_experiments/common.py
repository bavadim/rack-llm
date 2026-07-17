from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

REPO = Path(__file__).resolve().parents[3]
EXPERIMENTS = REPO / "experiments"
DATA = REPO / "data" / "pwseq-ifbench"
SOURCE_DATA = REPO / "data" / "pwseq-ifbench-v0.2-min" / "data"
ARTIFACT_ROOT = EXPERIMENTS / "artifacts"
ACTIVE_RUN_FILE = ARTIFACT_ROOT / "active_run"  # legacy pilot pointer; never used by new runs
_run_id = os.environ.get("PWSEQ_RUN_ID", "setup")
ARTIFACTS = ARTIFACT_ROOT / _run_id
CACHE = EXPERIMENTS / ".cache"
CONFIG_PATH = EXPERIMENTS / "config" / "paper.json"
STATE_FILE = ARTIFACTS / "RUN_STATE.json"


def load_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def stable_hash(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        for row in rows:
            handle.write(stable_json(row))
            handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def write_jsonl_once(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    """Create a frozen decision artifact once; identical retries are harmless."""
    materialized = list(rows)
    if path.exists():
        if read_jsonl(path) != materialized:
            raise RuntimeError(f"immutable JSONL artifact would change: {path}")
        return
    write_jsonl(path, materialized)


def jsonl_count(path: Path) -> int:
    with path.open(encoding="utf-8") as handle:
        return sum(1 for line in handle if line.strip())


def atomic_jsonl_command(
    stage: str,
    command: list[str],
    output: Path,
    *,
    expected_rows: int | None = None,
    cwd: Path = REPO,
    env: dict[str, str] | None = None,
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(output.suffix + ".partial")
    log_path = output.with_suffix(output.suffix + ".log")
    meta_path = output.with_suffix(output.suffix + ".meta.json")
    resolved_command = [
        str(partial) if item == str(output) else item for item in command
    ]
    if output.exists() and meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            actual = jsonl_count(output)
            if (
                meta.get("stage") == stage
                and meta.get("rows") == actual
                and meta.get("expected_rows") == expected_rows
                and meta.get("command") == resolved_command
                and meta.get("output_sha256") == file_hash(output)
                and (expected_rows is None or actual == expected_rows)
            ):
                return output
        except (OSError, ValueError, TypeError):
            pass
    with log_path.open("w", encoding="utf-8") as log_handle:
        completed = subprocess.run(
            resolved_command, cwd=cwd, env=env, text=True, stdout=log_handle,
            stderr=subprocess.STDOUT,
        )
    if completed.returncode != 0:
        error = RuntimeError(f"{stage} failed with exit code {completed.returncode}")
        issue(stage, error, command=resolved_command, log=str(log_path))
        raise error
    if not partial.exists():
        error = RuntimeError(f"{stage} did not create output")
        issue(stage, error, command=resolved_command)
        raise error
    actual = jsonl_count(partial)
    if expected_rows is not None and actual != expected_rows:
        error = RuntimeError(
            f"{stage} produced {actual} rows; expected {expected_rows}"
        )
        issue(stage, error, command=resolved_command)
        raise error
    os.replace(partial, output)
    write_json(meta_path, {
        "run_id": ARTIFACTS.name,
        "stage": stage,
        "rows": actual,
        "expected_rows": expected_rows,
        "command": resolved_command,
        "output_sha256": file_hash(output),
    })
    return output


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        value, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False
    ) + "\n"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".partial", delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def issue(stage: str, error: BaseException | str, **context: Any) -> None:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    message = str(error)
    trace = traceback.format_exc() if isinstance(error, BaseException) else ""
    row = {
        "run_id": ARTIFACTS.name,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "stage": stage,
        "error_type": type(error).__name__ if isinstance(error, BaseException) else "BLOCKER",
        "message": message,
        "traceback_sha256": hashlib.sha256(trace.encode()).hexdigest() if trace else None,
        "action": "recorded_not_fixed",
        **context,
    }
    with (ARTIFACTS / "issues.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(stable_json(row) + "\n")


def run_once(stage: str, command: list[str], *, cwd: Path = REPO, env: dict[str, str] | None = None) -> bool:
    try:
        subprocess.run(command, cwd=cwd, env=env, check=True)
        return True
    except Exception as exc:
        issue(stage, exc, command=command)
        return False


def frozen_manifest() -> dict[str, Any] | None:
    path = ARTIFACTS / "frozen_manifest.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def assert_frozen() -> dict[str, Any]:
    manifest = frozen_manifest()
    if manifest is None:
        raise RuntimeError("experiment is not frozen; run `make -C experiments freeze`")
    for rel, expected in manifest["files"].items():
        path = REPO / rel
        if not path.exists() or file_hash(path) != expected:
            raise RuntimeError(f"frozen input drift: {rel}")
    for raw_path, expected in manifest.get("external_files", {}).items():
        path = Path(raw_path)
        if not path.exists() or file_hash(path) != expected:
            raise RuntimeError(f"frozen external input drift: {path}")
    config = load_config()
    for key, root in [
        ("llama_cpp_revision", Path(config["native"]["llama_cpp_dir"])),
        ("ifbench_revision", CACHE / "ifbench"),
    ]:
        if key in manifest:
            actual = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=root, text=True
            ).strip()
            if actual != manifest[key]:
                raise RuntimeError(f"frozen checkout drift: {root}")
    return manifest


def run_state() -> str | None:
    if not STATE_FILE.exists():
        return None
    return json.loads(STATE_FILE.read_text(encoding="utf-8"))["state"]


def set_run_state(state: str, **details: Any) -> None:
    allowed = {
        None: {"FROZEN"},
        "FROZEN": {"RUNNING", "SUPERSEDED"},
        "RUNNING": {"RUN_COMPLETE", "FAILED", "SUPERSEDED"},
        "RUN_COMPLETE": {"ANALYZED", "SUPERSEDED"},
        "ANALYZED": {"READY_TO_ARCHIVE", "SUPERSEDED"},
        "READY_TO_ARCHIVE": {"ARCHIVED", "SUPERSEDED"},
    }
    current = run_state()
    if state not in allowed.get(current, set()):
        raise RuntimeError(f"invalid run state transition: {current} -> {state}")
    write_json(STATE_FILE, {"run_id": ARTIFACTS.name, "state": state, **details})


def python_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(EXPERIMENTS / "src")
    env["PLTCOLLECTS"] = f"{REPO.parent}:{env.get('PLTCOLLECTS', '')}"
    return env
