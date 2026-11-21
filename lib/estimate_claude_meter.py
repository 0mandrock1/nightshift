"""Bound forced Claude probes and flag overlapping Nightshift attempts."""

from contextlib import closing, contextmanager
from pathlib import Path
import sqlite3
import time

MIN_PROBE_GAP_SECONDS = 30
MAX_PROBE_EDGE_SECONDS = 60


def process_start(pid):
    try:
        # The command name can contain spaces or parentheses.
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[19] if fields[0] != "Z" else None
    except (OSError, IndexError):
        return None


@contextmanager
def transaction(path):
    with closing(sqlite3.connect(path, timeout=.25)) as db, db:
        db.execute("""CREATE TABLE IF NOT EXISTS attempts (
            id TEXT PRIMARY KEY, pid INTEGER, process_start TEXT, opened REAL, closed REAL
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS probe (
            id INTEGER PRIMARY KEY CHECK (id = 1), reserved_at REAL
        )""")
        db.execute("BEGIN IMMEDIATE")
        yield db


def register(path, attempt_id, pid):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with transaction(path) as db:
        now = time.time()
        for old_id, old_pid, old_start in db.execute(
            "SELECT id, pid, process_start FROM attempts WHERE closed IS NULL"
        ).fetchall():
            if old_start and process_start(old_pid) != old_start:
                db.execute("UPDATE attempts SET closed = ? WHERE id = ?", (now, old_id))
        db.execute("INSERT INTO attempts VALUES (?, ?, ?, ?, NULL)",
                   (attempt_id, pid, process_start(pid), now))


def reserve_probe(path):
    with transaction(path) as db:
        now = time.time()
        previous = db.execute("SELECT reserved_at FROM probe WHERE id = 1").fetchone()
        if previous and now - previous[0] < MIN_PROBE_GAP_SECONDS:
            return False
        db.execute("INSERT OR REPLACE INTO probe VALUES (1, ?)", (now,))
        return True


def close_attempt(path, attempt_id, before=None, after=None):
    with transaction(path) as db:
        now = time.time()
        # Close after fetching the final account reading so peers see the full bracket.
        db.execute("UPDATE attempts SET closed = ? WHERE id = ? AND closed IS NULL", (now, attempt_id))
        if before is not None and after is not None:
            return db.execute(
                """SELECT 1 FROM attempts
                   WHERE id != ? AND opened <= ? AND (closed IS NULL OR closed >= ?) LIMIT 1""",
                (attempt_id, after, before),
            ).fetchone() is not None
        return None


def pair_issue(before, after, start, end, overlaps):
    if not before or not after:
        return "missing_snapshot"
    if not before.get("fresh") or not after.get("fresh"):
        return "incompatible_snapshot"
    left, right = before["observed_at"], after["observed_at"]
    if left >= right or (before.get("sample_id") and before.get("sample_id") == after.get("sample_id")):
        return "same_or_older_snapshot"
    if any(s.get("probe_status") != "independent" or not s.get("sample_id") for s in (before, after)):
        return "independent_probe_unavailable"
    if not (-1 <= start - left <= MAX_PROBE_EDGE_SECONDS and -1 <= right - end <= MAX_PROBE_EDGE_SECONDS):
        return "probe_outside_run_edges"
    if overlaps is not False:
        return "overlapping_local_attempt" if overlaps else "local_overlap_unknown"
    return None
