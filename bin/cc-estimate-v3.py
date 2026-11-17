#!/usr/bin/env python3
"""Nightshift preflight, native attempt records, and chronological replay."""

import argparse
import collections
import html
import json
import math
import os
import pathlib
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
BIN = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(BIN.parent / "lib"))
from estimate_history import (
    claude_facts, codex_facts, import_claude_history, import_history, live_rows, read, session_root,
)

WINDOWS = ("5h", "7d")


def state_path():
    runs = pathlib.Path(os.environ.get("CC_RUNS", pathlib.Path.home() / "ops/cc-runs"))
    return pathlib.Path(os.environ.get("CC_ESTIMATE_STATE", runs / ".estimate-v3"))


def emit(item):
    print(json.dumps(item, ensure_ascii=False, allow_nan=False, separators=(",", ":")))


def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as f:
        temporary = pathlib.Path(f.name)
        try:
            json.dump(value, f, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def resolve(backend, model):
    if backend == "codex":
        return {"": "gpt-6-luna", "sonnet": "gpt-6-luna", "haiku": "gpt-6-luna", "opus": "gpt-6-sol"}.get(model, model)
    return model or "default"


def model_key(backend, model):
    if backend == "claude" and model.startswith("claude-"):
        tier = model.split("-")[1]
        if tier in ("sonnet", "opus", "haiku"):
            return tier
    return model


def snapshot(backend):
    if backend == "codex":
        command = ["sh", str(BIN / "cc-codex-usage.sh"), "--json"]
        env = os.environ | {"CC_CODEX_USAGE_BIN": os.environ.get("CC_CODEX_USAGE_BIN", "codex" if os.environ.get("CC_CODEX_BIN", "codex") == "codex" else "false")}
    else:
        cli = os.environ.get("CC_USAGE_CLI", "/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js")
        command = ["node", cli, "--ratelimit-json"]
        env = os.environ
    data = {}
    try:
        with subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              start_new_session=True) as proc:
            try:
                output, _ = proc.communicate(timeout=8 if backend == "codex" else 15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.communicate()
                raise
            if proc.returncode == 0:
                value = json.loads(output)
                if isinstance(value, dict):
                    data = value
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    now = int(time.time())
    source = data.get("source") or "unavailable"
    observed = now if source == "codex-app-server" else data.get("ts")
    fresh = isinstance(observed, (int, float)) and 0 <= now - observed <= 240 and source not in ("none", "stale")
    windows = {}
    for key in WINDOWS:
        used, reset = data.get("util" + key), data.get("reset" + key)
        value = round(used * 100, 2) if type(used) in (float, int) and 0 <= used <= 10 else None
        reset = reset if type(reset) in (int, float) and reset >= 0 else None
        windows[key] = {"used_percent": value, "reset_at": reset,
                        "usable": fresh and value is not None and (not reset or reset > now)}
    allowed = data.get("ordinaryUsageAllowed")
    return {"backend": backend, "source": source, "observed_at": observed, "fresh": fresh, "windows": windows,
            "ordinary_usage_allowed": allowed if type(allowed) is bool else None}


def percentile(values, fraction):
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    return round(ordered[lower] + (index - lower) * (ordered[upper] - ordered[lower]), 1)


def select_history(state):
    def key(row):
        fact = row.get("provider") or {}
        native_id = fact.get("thread_id") or fact.get("session_id")
        if native_id:
            return row["backend"], native_id
        return row["backend"], row["attempt_id"]

    baseline = read(state / "history.json", {}) or {}
    rows = {key(row): row for row in baseline.get("rows", [])}
    rows.update((key(row), row) for row in live_rows(state))
    return list(rows.values())


def forecast(rows, backend, model, effort, cutoff, task_class=None):
    key = model_key(backend, model)
    known = [r for r in rows if r.get("backend") == backend and r.get("outcome") == "ok"
             and r.get("model") and r.get("model_source") != "resolved_only"
             and (r["model"] == model if backend == "claude" and model.startswith("claude-")
                  else model_key(backend, r["model"]) == key)
             and r.get("finished_at") is not None and (r.get("recorded_at") or r["finished_at"]) < cutoff
             and type(r.get("seconds")) in (int, float) and r["seconds"] > 0]
    scope = "model"
    same_class = [r for r in known if r.get("task_class") == task_class] if task_class else []
    if len(same_class) >= 10:
        known, scope = same_class, "model_class"
    exact = [r for r in known if r.get("effort") == effort] if effort else []
    if len(exact) >= 10:
        known, scope = exact, scope + "_effort"
    result = {"n": len(known), "scope": scope, "status": "insufficient_history",
              "p50_seconds": None, "p90_seconds": None}
    if len(known) >= 5:
        values = [r["seconds"] for r in known]
        result.update(status="provisional", p50_seconds=percentile(values, .5),
                      p90_seconds=percentile(values, .9),
                      sources=dict(collections.Counter(r.get("source", "wrapper") for r in known)))
    return result


def policy(quotas, deadline, eta, now):
    if deadline is not None and now >= deadline:
        return {"action": "block", "reason": "deadline_elapsed"}
    warnings = []
    codex = quotas.get("codex") or {}
    if codex.get("fresh") and codex.get("ordinary_usage_allowed") is False:
        resets = [w["reset_at"] for w in codex["windows"].values() if w["usable"]
                  and w["used_percent"] >= 100 and w["reset_at"]]
        return {"action": "defer", "reason": "codex_provider_denied", "retry_at": max(resets, default=None)}
    windows = [w for q in quotas.values() for w in q["windows"].values()]
    if not windows or any(not w["usable"] for w in windows):
        warnings.append("quota_unavailable")
    if any(w["usable"] and w["used_percent"] >= 90 for w in windows):
        warnings.append("current_quota_high")
    hi = eta.get("p90_seconds", eta.get("upper_seconds"))
    if deadline is not None and (hi is None or now + hi > deadline):
        warnings.append("deadline_at_risk")
    if warnings:
        return {"action": "warn", "reason": warnings[0], "warnings": warnings}
    return {"action": "allow", "reason": "no_observed_limit"}


def plan_steps(path, mode, backend):
    steps = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) < 3:
            raise ValueError("invalid plan line")
        fields += [""] * (6 - len(fields))
        selected = fields[4 if mode == "chain" else 5] or backend
        model = fields[3] or (("" if selected == "codex" else "sonnet") if mode == "chain" else "haiku")
        if mode == "swarm" and model.startswith("local:"):
            selected = "local"
        steps.append((fields[0], selected, model, False))
    return steps


def estimate(args):
    now = time.time()
    rows = select_history(state_path())
    specifications = plan_steps(args.plan, args.mode, args.backend) if args.plan else [
        (args.id or "run", args.backend, args.model, False)]
    if args.plan and args.mode == "swarm" and args.fanin:
        specifications.append(("fan-in", args.backend, "sonnet", True))
    quotas, steps = {}, []
    for name, backend, requested, fanin in specifications:
        if backend not in ("claude", "codex", "local"):
            raise ValueError("invalid backend")
        if backend not in quotas and backend != "local" and (backend == "codex" or args.claude_quota):
            quotas[backend] = snapshot(backend)
        model = resolve(backend, requested)
        effort = (args.effort or None) if backend == "codex" else None
        steps.append({"name": name, "backend": backend, "requested_model": requested, "model": model,
                      "effort": effort, "fanin": fanin,
                      "eta": forecast(rows, backend, model, effort, now, args.task_class)})
    if not steps:
        raise ValueError("empty plan")
    eta = steps[0]["eta"]
    if args.plan:
        eta = {"status": "insufficient_history", "p50_seconds": None, "upper_seconds": None}
        if all(s["eta"]["p50_seconds"] is not None for s in steps):
            serial = [s for s in steps if args.mode == "chain" or s["fanin"]]
            parallel = [s for s in steps if s not in serial]
            values = {}
            for key, name in (("p50_seconds", "p50_seconds"), ("p90_seconds", "upper_seconds")):
                lanes = [0.0] * min(args.maxpar, max(1, len(parallel)))
                for step in parallel:
                    i = min(range(len(lanes)), key=lanes.__getitem__)
                    lanes[i] += step["eta"][key]
                values[name] = round(max(lanes) + sum(s["eta"][key] for s in serial), 1)
            eta = {"status": "schedule_heuristic", **values}
    result = {"schema": 3, "mode": args.mode, "generated_at": now, "eta": eta, "steps": steps, "quotas": quotas,
              "quota_forecast": {"status": "unavailable", "reason": "awaiting_clean_pairs"},
              "deadline_epoch": args.deadline, "task_class": args.task_class,
              "decision": policy(quotas, args.deadline, eta, now)}
    if args.attempt:
        result["attempt_id"] = str(uuid.uuid4())
    if args.output:
        write(args.output, result)
    if args.format == "json":
        emit(result)
    else:
        render(result, markup=args.format == "html")


def render(data, markup=True):
    eta = data["eta"]
    label = " · ".join(f"{s['backend']}/{s['model']}" + (f" · {s['effort']}" if s["effort"] else "")
                       for s in data["steps"][:3])
    if len(data["steps"]) > 3:
        label += f" · +{len(data['steps']) - 3}"
    lines = [label]
    if eta["p50_seconds"] is None:
        lines.append("ETA н/д · історія " + str(eta.get("n", sum(s["eta"]["n"] for s in data["steps"]))))
    else:
        upper = eta.get("p90_seconds", eta.get("upper_seconds"))
        suffix = f" · n={eta['n']}; попередньо" if "n" in eta else " · сума/розклад кроків; попередньо"
        lines.append(f"ETA {eta['p50_seconds']/60:.1f} хв · верх {upper/60:.1f} хв{suffix}")
    for backend, q in data["quotas"].items():
        windows = []
        for key in WINDOWS:
            w = q["windows"][key]
            p = w["used_percent"]
            windows.append(f"{key} {p:g}%" + ("" if w["usable"] else " (неактуально)") if p is not None else f"{key} н/д")
        lines.append(f"{backend} " + " · ".join(windows) + " · " + q["source"])
    lines.append("Прогноз витрат квоти н/д")
    if data["decision"]["action"] != "allow":
        descriptions = {"quota_unavailable": "поточна квота недоступна", "codex_provider_denied": "Codex призупинив звичайні запуски",
                        "current_quota_high": "залишок квоти малий", "deadline_at_risk": "ризик вийти за дедлайн",
                        "deadline_elapsed": "вказаний дедлайн минув"}
        reasons = data["decision"].get("warnings", [data["decision"]["reason"]])
        lines.extend(descriptions.get(reason, reason) for reason in reasons)
    retry_at = data["decision"].get("retry_at")
    if retry_at:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        stamp = datetime.fromtimestamp(retry_at, ZoneInfo("Europe/Kyiv"))
        lines.append("Повтор після " + stamp.strftime("%d.%m %H:%M") + " за Києвом")
    output = "\n".join(lines)
    print("<pre>\n" + html.escape(output, quote=False) + "\n</pre>" if markup else output)


def quota_delta(before, after):
    """Account changes measured around a run, with unknown external attribution."""
    results = {}
    for key in WINDOWS:
        if not before or not after:
            reason = "missing_snapshot"
        elif before["backend"] != after["backend"] or not before["fresh"] or not after["fresh"]:
            reason = "incompatible_snapshot"
        elif before["observed_at"] >= after["observed_at"]:
            reason = "same_or_older_snapshot"
        else:
            a, b = before["windows"][key], after["windows"][key]
            if not a["usable"] or not b["usable"]:
                reason = "window_unavailable"
            elif a["reset_at"] is None or b["reset_at"] is None:
                reason = "window_changed_or_unknown"
            elif a["reset_at"] != b["reset_at"] and not (
                before["backend"] == "codex" and abs(a["reset_at"] - b["reset_at"]) <= 1
                and min(a["reset_at"], b["reset_at"]) > after["observed_at"]
            ):
                reason = "window_changed_or_unknown"
            elif b["used_percent"] < a["used_percent"]:
                reason = "decreased"
            else:
                match = "equal_reset" if a["reset_at"] == b["reset_at"] else "codex_reset_jitter_1s"
                results[key] = {"status": "account_delta", "attribution": "unknown", "window_match": match,
                                "percentage_points": round(b["used_percent"] - a["used_percent"], 2)}
                continue
        results[key] = {"status": "unavailable", "reason": reason}
    return results


def finalize(args):
    data = read(args.preflight)
    if not data:
        return
    step = data["steps"][0]
    backend = step["backend"]
    mono = args.end_ns - args.start_ns if args.start_ns and args.end_ns else None
    timed = mono is not None and mono >= 0
    fact = {}
    if timed:
        fact = codex_facts(args.run_dir, session_root()) if backend == "codex" else claude_facts(args.run_dir)
    before = data["quotas"].get(backend)
    after = snapshot(backend) if timed else None
    record = {"attempt_id": data["attempt_id"], "run_id": args.run_dir.name,
              "backend": backend, "requested_model": step["requested_model"], "resolved_model": step["model"],
              "model": fact.get("model") or step["model"], "effort": fact.get("effort") or step["effort"],
              "model_source": "provider" if fact.get("model") else "resolved_only",
              "effort_source": "provider" if fact.get("effort") else "requested" if step["effort"] else "unknown",
              "task_class": data.get("task_class"), "mode": os.environ.get("CC_TELEMETRY_KIND", "run"),
              "plan_id": os.environ.get("CC_ESTIMATE_PLAN_ID") or os.environ.get("CC_PARENT_RUN_ID"),
              "recorded_source_version": 3,
              "outcome": args.outcome, "cli_rc": args.rc, "started_at": args.start_epoch or None,
              "finished_at": args.end_epoch or None, "recorded_at": time.time(),
              "seconds": round(mono / 1e9, 3) if timed else None,
              "source": "wrapper_monotonic" if timed else "preflight_only",
              "quota_before": before, "quota_after": after,
              "quota_observed_delta": quota_delta(before, after),
              "prediction": data, "provider": fact}
    write(state_path() / "attempts" / (record["attempt_id"] + ".json"), record)
    write(args.run_dir / "attempt-v3.json", record)


def replay(rows):
    by_backend = collections.defaultdict(list)
    for row in sorted(rows, key=lambda r: r.get("started_at") or 0):
        if row.get("outcome") != "ok" or not row.get("seconds") or not row.get("started_at"):
            continue
        if row.get("model_source") == "resolved_only":
            continue
        estimate = forecast(rows, row["backend"], row["model"], row.get("effort"), row["started_at"], row.get("task_class"))
        by_backend[row["backend"]].append((row["seconds"], estimate))
    result = {}
    for backend, samples in by_backend.items():
        valid = [(truth, info) for truth, info in samples if info["p90_seconds"] is not None]
        misses = sum(truth > info["p90_seconds"] for truth, info in valid)
        errors = [abs(truth - info["p50_seconds"]) for truth, info in valid]
        n = len(valid)
        limits = None
        if n:
            z = 1.96
            p = misses / n
            center = (p + z*z/(2*n)) / (1 + z*z/n)
            radius = z * math.sqrt(p*(1-p)/n + z*z/(4*n*n)) / (1 + z*z/n)
            limits = [round(max(0, center-radius), 3), round(min(1, center+radius), 3)]
        pinball = [max(.9*(truth - info["p90_seconds"]), -.1*(truth - info["p90_seconds"])) for truth, info in valid]
        result[backend] = {"evaluated": len(samples), "with_eta": n, "above_p90": misses,
                           "above_p90_wilson95": limits,
                           "mean_absolute_error_seconds": round(statistics.mean(errors), 1) if errors else None,
                           "median_absolute_error_seconds": round(statistics.median(errors), 1) if errors else None,
                           "p90_pinball_seconds": round(statistics.mean(pinball), 1) if pinball else None}
    emit(result)


def timestamp(value):
    result = float(value)
    if not math.isfinite(result):
        raise argparse.ArgumentTypeError("deadline must be a finite epoch time")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("predict")
    p.add_argument("--backend", required=True, choices=("codex", "claude"))
    p.add_argument("--model", default="")
    p.add_argument("--effort")
    p.add_argument("--id")
    p.add_argument("--plan", type=pathlib.Path)
    p.add_argument("--mode", choices=("run", "chain", "swarm"), default="run")
    p.add_argument("--maxpar", type=lambda value: max(1, int(value)), default=1)
    p.add_argument("--deadline", type=timestamp)
    p.add_argument("--task-class", default=os.environ.get("CC_ESTIMATE_TASK_CLASS") or None)
    p.add_argument("--fanin", action="store_true")
    p.add_argument("--claude-quota", action="store_true")
    p.add_argument("--attempt", action="store_true")
    p.add_argument("--output", type=pathlib.Path)
    p.add_argument("--format", choices=("json", "html", "text"), default="json")
    p = sub.add_parser("render")
    p.add_argument("preflight", type=pathlib.Path)
    p = sub.add_parser("finalize")
    p.add_argument("run_dir", type=pathlib.Path)
    p.add_argument("preflight", type=pathlib.Path)
    p.add_argument("outcome")
    p.add_argument("rc", type=int)
    for field in ("start_ns", "start_epoch", "end_ns", "end_epoch"):
        p.add_argument(field, type=int)
    p = sub.add_parser("backfill")
    p.add_argument("runs", type=pathlib.Path)
    p.add_argument("--include-claude", action="store_true")
    sub.add_parser("replay")
    p = sub.add_parser("snapshot")
    p.add_argument("backend", choices=("codex", "claude"))
    sub.add_parser("clock")
    args = parser.parse_args()
    if args.command == "predict":
        estimate(args)
    elif args.command == "render":
        render(read(args.preflight))
    elif args.command == "finalize":
        finalize(args)
    elif args.command == "backfill":
        rows, counts = import_history(args.runs, session_root())
        counts.update(timed_attempts=len(rows), timed_ok=sum(row["outcome"] == "ok" for row in rows))
        previous = read(state_path() / "history.json", {}) or {}
        if args.include_claude:
            claude, claude_counts = import_claude_history(args.runs)
            counts.update(claude_counts)
        else:
            claude = [row for row in previous.get("rows", []) if row["backend"] == "claude"]
        write(state_path() / "history.json", {"schema": 3, "generated_at": time.time(), "rows": rows + claude})
        emit(counts)
    elif args.command == "replay":
        replay(select_history(state_path()))
    elif args.command == "snapshot":
        emit(snapshot(args.backend))
    else:
        print(time.monotonic_ns(), int(time.time()))


if __name__ == "__main__":
    main()
