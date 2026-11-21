"""Historical attempt import. Provider transcripts are joined by their native IDs."""

import collections
import json
import os
import pathlib
import re
import subprocess


def documents(path):
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict):
                    yield item
    except OSError:
        return


def read(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def artifact_times(directory, names):
    results = []
    for name in names:
        try:
            results.append((directory / name).stat().st_mtime)
        except OSError:
            continue
    return results


def codex_facts(directory, sessions):
    thread = None
    usage = collections.Counter()
    count = 0
    for event in documents(directory / "events.jsonl"):
        if event.get("type") == "thread.started":
            thread = event.get("thread_id")
        if event.get("type") != "turn.completed" or not isinstance(event.get("usage"), dict):
            continue
        count += 1
        for key, value in event["usage"].items():
            if isinstance(value, int) and value >= 0:
                usage[key] += value

    fact = {"thread_id": thread, "completed_turns": count, "usage": dict(usage) if count else None}
    if not isinstance(thread, str) or not re.fullmatch(r"[0-9a-f-]{36}", thread):
        return fact
    hits = list(sessions.glob(f"*/*/*/*{thread}.jsonl"))
    if len(hits) != 1:
        return fact
    return fact | codex_session(hits[0], thread)


def codex_session(path, thread):
    from datetime import datetime

    def stamp(value):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except (ValueError, AttributeError):
            return None

    ok = False
    model = effort = version = started = finished = None
    starts = {}
    complete = 0
    for record in documents(path):
        kind = record.get("type")
        payload = record.get("payload")
        time = stamp(record.get("timestamp"))
        if not isinstance(payload, dict):
            continue
        if kind == "session_meta":
            ok = (payload.get("id") or payload.get("session_id")) == thread
            version = payload.get("cli_version")
        if kind == "turn_context" and model is None:
            model, effort = payload.get("model"), payload.get("effort")
        if kind != "event_msg":
            continue
        turn = payload.get("turn_id")
        if payload.get("type") == "task_started" and time is not None:
            starts[turn] = payload.get("started_at") if isinstance(payload.get("started_at"), int) else time
        if payload.get("type") == "task_complete" and time is not None:
            completed = payload.get("completed_at")
            completed = completed if isinstance(completed, int) else time
            began = payload.get("started_at")
            began = began if isinstance(began, int) else starts.get(turn)
            if began is None and isinstance(payload.get("duration_ms"), int):
                began = completed - payload["duration_ms"] / 1000
            if began is not None and completed > began:
                started = began if started is None else min(started, began)
                finished = completed if finished is None else max(finished, completed)
                complete += 1
    if not ok:
        return {}
    return {"model": model, "effort": effort, "cli_version": version,
            "started_at": started, "finished_at": finished, "timed_turns": complete}


def claude_facts(directory):
    usage = read(directory / "usage.json", {})
    try:
        session_id = (directory / "session_id").read_text().strip()
    except OSError:
        session_id = None
    if not isinstance(usage, dict) or not session_id or pathlib.Path(usage.get("session") or "").stem != session_id:
        return {"session_id": session_id}
    models = [m for m in usage.get("models", []) if m.get("model", "").startswith("claude-")]
    model = max(models, key=lambda x: x.get("output", 0), default={}).get("model")
    tokens = {key: sum(m.get(key, 0) for m in models) for key in ("input", "output", "cache_r", "cache_w")}
    return {"session_id": session_id, "model": model, "usage": tokens if models else None}


def import_history(root, sessions):
    rows = []
    seen = set()
    inventory = collections.Counter()
    for directory in sorted(root.iterdir()):
        events = directory / "events.jsonl"
        if not events.is_file():
            continue
        fact = codex_facts(directory, sessions)
        inventory["codex_artifacts"] += 1
        thread = fact.get("thread_id")
        if not thread or thread in seen or not fact.get("model"):
            continue
        seen.add(thread)
        inventory["matched_thread"] += 1
        try:
            status = int((directory / "exit_code").read_text())
        except (OSError, ValueError):
            status = None
        start, finish = fact.get("started_at"), fact.get("finished_at")
        outcome = {0: "ok", 3: "quota", 4: "ambiguous", 124: "timeout", 2: "fail"}.get(status, "unknown")
        if outcome == "ok" and not fact["completed_turns"]:
            outcome = "unknown"
        if start is None or finish is None:
            continue
        recorded = max([finish] + artifact_times(directory, ("exit_code", "events.jsonl")))
        rows.append({"backend": "codex", "run_id": directory.name,
                     "attempt_id": thread, "model": fact["model"], "effort": fact["effort"],
                     "started_at": start, "finished_at": finish, "seconds": finish - start,
                     "recorded_at": recorded, "outcome": outcome, "source": "codex_session", "provider": fact})
    return rows, dict(inventory)


def live_rows(state):
    for path in (state / "attempts").glob("*.json"):
        item = read(path)
        if isinstance(item, dict):
            yield item


def session_root():
    codex_home = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
    return codex_home / "sessions"


def claude_run_records(root):
    creds = pathlib.Path(os.environ.get("CC_PG_CREDS", root / "creds-pg.env"))
    password = next((line.partition("=")[2] for line in creds.read_text().splitlines()
                     if line.startswith("POSTGRES_PASSWORD=")), None)
    if not password:
        raise ValueError("Postgres credentials unavailable")
    command = ["docker", "exec", "-i", "-e", "PGPASSWORD",
               os.environ.get("CC_PG_CONTAINER", "mandrock-kb-postgres"), "psql",
               "-XqAt", "-v", "ON_ERROR_STOP=1",
               "-h", os.environ.get("CC_PG_HOST", "127.0.0.1"),
               "-p", os.environ.get("CC_PG_PORT", "5432"),
               "-U", os.environ.get("CC_PG_USER", "mandrock"),
               "-d", os.environ.get("CC_PG_DB", "mandrock_kb")]
    query = """BEGIN READ ONLY;
    SELECT coalesce(json_agg(r), '[]') FROM (
      SELECT run_id, model AS tier, status AS outcome, extract(epoch FROM started_at) AS started_at,
             extract(epoch FROM finished_at) AS finished_at, duration_s AS seconds,
             extract(epoch FROM created_at) AS recorded_at
      FROM swarm.runs WHERE kind IN ('run','lane','fanin') AND duration_s > 0
        AND started_at IS NOT NULL AND finished_at > started_at
        AND (model IN ('sonnet','opus','haiku') OR model LIKE 'claude-%')
    ) AS r;
    ROLLBACK;
    """
    result = subprocess.run(command, input=query, text=True, check=True, capture_output=True,
                            timeout=20, env=os.environ | {"PGPASSWORD": password})
    return json.loads(result.stdout)


def import_claude_history(root):
    counts = collections.Counter()
    rows = []
    for row in claude_run_records(root):
        counts["claude_db_candidates"] += 1
        directory = root / row["run_id"]
        if (directory / "events.jsonl").is_file() or not (directory / "usage.json").is_file():
            continue
        payload = read(directory / "usage.json") or {}
        models = [m for m in payload.get("models", []) if str(m.get("model", "")).startswith("claude-")]
        if not models:
            continue
        evidence = claude_facts(directory)
        exact_model = evidence.get("model")
        counts["claude_session_id_matches"] += bool(exact_model)
        recorded = max(row["recorded_at"], row["finished_at"],
                       *artifact_times(directory, ("exit_code", "usage.json", "session_id")))
        rows.append(row | {"backend": "claude", "recorded_at": recorded, "attempt_id": "legacy:" + row["run_id"],
                           "model": exact_model or row["tier"], "source": "mtime_proxy",
                           "model_source": "matched_session" if exact_model else "legacy_usage",
                           "provider": evidence if exact_model else {}})
        counts["claude_imported"] += 1
    return rows, dict(counts)
