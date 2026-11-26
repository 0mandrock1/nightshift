#!/usr/bin/env python3
"""Atomically publish the small queue lifecycle contract consumed by Runwatch."""
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def atomic_text(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def identity(pid: int) -> tuple[str, list[str]]:
    raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    argv = [v.decode(errors="replace") for v in raw.rstrip(b"\0").split(b"\0")]
    stat = Path(f"/proc/{pid}/stat").read_text()
    tail = stat[stat.rfind(")") + 2 :].split()
    if len(tail) <= 19 or tail[0] in {"Z", "X"}:
        raise RuntimeError("worker process is not live")
    return tail[19], argv


def main() -> int:
    if len(sys.argv) not in {3, 4, 5}:
        print("usage: cc-queue-state.py RUN_DIR STATUS [STARTED_AT] [ENDED_AT]", file=sys.stderr)
        return 2
    run_dir = Path(sys.argv[1]).resolve()
    status = sys.argv[2].upper()
    if not re.fullmatch(r"[A-Za-z0-9._-]+-\d{8}-(?:\d{4}|\d{6}|T\d{6}Z)", run_dir.name):
        print("invalid run directory name", file=sys.stderr)
        return 2
    if status not in {"QUEUED", "STARTING", "RUNNING", "BLOCKED", "FAILED", "TIMEOUT", "COMPLETE"}:
        print("invalid queue status", file=sys.stderr)
        return 2
    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    meta_path = run_dir / "queue.meta"
    try:
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    except (OSError, json.JSONDecodeError):
        meta = {}
    pid = os.getppid()
    start_ticks, argv = identity(pid)
    meta.update({
        "schema": 1,
        "run_id": run_dir.name,
        "status": status,
        "queued_at": meta.get("queued_at") or now,
        "worker_pid": str(pid),
        "worker_start_ticks": start_ticks,
        "worker_argv": argv,
    })
    if status == "RUNNING" and not meta.get("started_at"):
        meta["started_at"] = sys.argv[3] if len(sys.argv) >= 4 and sys.argv[3] else now
    elif len(sys.argv) >= 4 and sys.argv[3]:
        meta["started_at"] = sys.argv[3]
    if len(sys.argv) >= 5 and sys.argv[4]:
        meta["ended_at"] = sys.argv[4]
    try:
        atomic_text(meta_path, json.dumps(meta, separators=(",", ":")) + "\n")
        atomic_text(run_dir / "queue.pid", f"{pid}\n")
        atomic_text(run_dir / "queue.status", status + "\n")
    except OSError as exc:
        print(f"queue state write failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
