#!/usr/bin/env python3
"""Nightshift preflight, native attempt records, and chronological replay."""

import argparse
import collections
import html
import json
import math
import os
import pathlib
import re
import signal
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
BIN = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(BIN.parent / "lib"))
import estimate_claude_meter as claude_meter
import estimate_eta
import estimate_quota
from estimate_history import (
    claude_facts, codex_facts, import_claude_history, import_history, live_rows, read, session_root,
)

WINDOWS = ("5h", "7d")
SHADOW_RECENT = {"claude": None, "codex": 24}


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


def snapshot(backend, claude_option=None):
    started = time.monotonic()
    if backend == "codex":
        command = ["sh", str(BIN / "cc-codex-usage.sh"), "--json"]
        env = os.environ | {"CC_CODEX_USAGE_BIN": os.environ.get("CC_CODEX_USAGE_BIN", "codex" if os.environ.get("CC_CODEX_BIN", "codex") == "codex" else "false")}
    else:
        cli = os.environ.get("CC_USAGE_CLI", "/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js")
        # Default previews reuse the local account reading. Its cold-start
        # inference cost and latency belong only to explicitly measured runs.
        command = ["node", cli, "--ratelimit-json", claude_option or "--cache-only"]
        env = os.environ
    data = {}
    failure = "provider_read_failed"
    try:
        with subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              start_new_session=True) as proc:
            try:
                timeout = 12 if backend == "codex" else 28 if claude_option == "--force" else 15
                output, _ = proc.communicate(timeout=timeout)
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
                    failure = None
    except subprocess.TimeoutExpired:
        failure = "timeout"
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    now = time.time()
    source = data.get("source") or "unavailable"
    observed = now if source == "codex-app-server" else data.get("ts")
    fresh = isinstance(observed, (int, float)) and 0 <= now - observed <= 240 and source not in ("none", "stale")
    windows = {}
    for key in WINDOWS:
        used, reset = data.get("util" + key), data.get("reset" + key)
        value = round(used * 100, 2) if type(used) in (float, int) and 0 <= used <= 10 else None
        reset = reset if type(reset) in (int, float) and reset >= 0 else None
        duration = data.get("duration" + key)
        windows[key] = {"used_percent": value, "reset_at": reset,
                        "duration_minutes": duration,
                        "usable": fresh and value is not None and (not reset or reset > now)}
    allowed = data.get("ordinaryUsageAllowed")
    return {"backend": backend, "source": source, "observed_at": observed, "fresh": fresh, "windows": windows,
            "sample_id": data.get("sampleId"),
            **({"probe_end": data["probeEnd"]} if "probeEnd" in data else {}),
            "probe_elapsed_seconds": round(time.monotonic() - started, 3),
            "probe_error": data.get("probeError") or failure,
            "plan_type": data.get("planType"),
            "ordinary_usage_allowed": allowed if type(allowed) is bool else None}


def measured_claude_snapshot(meter, *, allow_probe=True):
    if not allow_probe:
        return snapshot("claude", "--cache-only") | {"probe_status": "skipped_without_before"}
    try:
        reserved = claude_meter.reserve_probe(meter)
    except (OSError, sqlite3.Error) as error:
        print(f"Claude quota probe reservation: {error}", file=sys.stderr)
        return snapshot("claude", "--cache-only") | {"probe_status": "control_unavailable"}
    if not reserved:
        return snapshot("claude", "--cache-only") | {"probe_status": "throttled"}
    reading = snapshot("claude", "--force")
    independent = reading["fresh"] and reading["source"] == "live" and bool(reading["sample_id"])
    return reading | {"probe_status": "independent" if independent else "probe_unavailable"}


def percentile(values, fraction):
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    return round(ordered[lower] + (index - lower) * (ordered[upper] - ordered[lower]), 1)


def merge_attempts(historical, live):
    def key(row):
        fact = row.get("provider") or {}
        native_id = fact.get("thread_id") or fact.get("session_id")
        if native_id:
            return row["backend"], native_id
        return row["backend"], row["attempt_id"]

    rows = {key(row): row for row in historical}
    rows.update((key(row), row) for row in live)
    return list(rows.values())


def available_before(row, cutoff):
    finished = row.get("finished_at")
    return finished is not None and max(finished, row.get("recorded_at") or finished) < cutoff


def select_history(state, cutoff=None):
    baseline = read(state / "history.json", {}) or {}
    historical, live = baseline.get("rows", []), live_rows(state)
    if cutoff is not None:
        historical = [row for row in historical if available_before(row, cutoff)]
        live = (row for row in live if available_before(row, cutoff))
    return merge_attempts(historical, live)


def quota_history(state, attempts):
    baseline = read(state / "history.json", {}) or {}
    samples = {row["thread_id"]: row for row in baseline.get("codex_quota", [])}
    for attempt in attempts:
        thread = (attempt.get("provider") or {}).get("thread_id")
        if thread and "codex_quota" in attempt:
            sample = attempt["codex_quota"]
            if sample.get("windows"):
                samples[thread] = sample
            else:
                samples.pop(thread, None)
    return list(samples.values())


def forecast(rows, backend, model, effort, cutoff, task_class=None):
    key = model_key(backend, model)
    known = [r for r in rows if r.get("backend") == backend and r.get("outcome") == "ok"
             and r.get("model") and r.get("model_source") != "resolved_only"
             and (r["model"] == model if backend == "claude" and model.startswith("claude-")
                  else model_key(backend, r["model"]) == key)
             and available_before(r, cutoff)
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


def policy(quotas, deadline, eta, now, quota_forecast=None):
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
    if hi is not None and any(
        (window := codex.get("windows", {}).get(key, {})).get("usable") and window.get("reset_at")
        and window["reset_at"] > now + hi and window["used_percent"] + tip["planning_upper_pp"] >= 100
        for key, tip in (quota_forecast or {}).get("windows", {}).items() if "planning_upper_pp" in tip
    ):
        warnings.append("forecast_quota_at_risk")
    if deadline is not None and (hi is None or now + hi > deadline):
        warnings.append("deadline_at_risk")
    if warnings:
        return {"action": "warn", "reason": warnings[0], "warnings": warnings}
    return {"action": "allow", "reason": "no_observed_limit"}


def task_class_from_file(path):
    if path:
        try:
            with path.open(encoding="utf-8", errors="replace") as task:
                for line in task.read(2048).splitlines()[:12]:
                    match = re.fullmatch(r"(?:# |<!-- )?Task class: ([a-z][a-z0-9_-]{0,31})(?: -->)?", line.strip(), re.I)
                    if match:
                        return match[1].lower()
        except OSError:
            pass
    return None


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
        steps.append((fields[0], selected, model, False, pathlib.Path(fields[2 if mode == "chain" else 1])))
    return steps


def estimate(args):
    now = time.time()
    state = state_path()
    rows = select_history(state, now)
    samples = quota_history(state, rows)
    specifications = plan_steps(args.plan, args.mode, args.backend) if args.plan else [
        (args.id or "run", args.backend, args.model, False, getattr(args, "task", None))]
    if args.plan and args.mode == "swarm" and args.fanin:
        specifications.append(("fan-in", args.backend, "sonnet", True, pathlib.Path(str(args.plan)+".fanin")))
    quotas, steps = {}, []
    attempt_id = str(uuid.uuid4()) if args.attempt else None
    meter = state / "claude-meter.sqlite3"
    probe_enabled = os.environ.get("CC_ESTIMATE_CLAUDE_PROBES") == "1"
    tracked = False
    if attempt_id and args.backend == "claude" and not args.plan and (probe_enabled or meter.exists()):
        try:
            claude_meter.register(meter, attempt_id, args.wrapper_pid or os.getppid())
            tracked = True
        except (OSError, sqlite3.Error) as error:
            print(f"Claude quota attempt registration: {error}", file=sys.stderr)
    shadow = os.environ.get("CC_ESTIMATE_ETA_SHADOW", "1") == "1"
    for name, backend, requested, fanin, task_path in specifications:
        if backend not in ("claude", "codex", "local"):
            raise ValueError("invalid backend")
        if backend not in quotas and backend != "local" and (backend == "codex" or args.claude_quota):
            if backend == "claude" and attempt_id and probe_enabled:
                quotas[backend] = (measured_claude_snapshot(meter) if tracked else
                                   snapshot(backend, "--cache-only") | {"probe_status": "control_unavailable"})
            else:
                quotas[backend] = snapshot(backend)
        model = resolve(backend, requested)
        effort = (args.effort or None) if backend == "codex" else None
        mode = ("chain_step" if args.mode == "chain" else "fanin" if fanin else "lane") if args.plan else (
            os.environ.get("CC_TELEMETRY_KIND") or "run")
        task_class = args.task_class or task_class_from_file(task_path)
        step = {"name": name, "backend": backend, "requested_model": requested, "model": model,
                "effort": effort, "fanin": fanin, "mode": mode, "task_class": task_class,
                "eta": forecast(rows, backend, model, effort, now, task_class)}
        if shadow and backend in SHADOW_RECENT:
            step["eta_shadow"] = estimate_eta.measured_candidate(
                rows, backend, model, effort, now, task_class, step["eta"]) or estimate_eta.candidate(
                rows, backend, model, effort, now, task_class, mode, recent=SHADOW_RECENT[backend])
        steps.append(step)
    if not steps:
        raise ValueError("empty plan")
    eta = steps[0]["eta"]
    if args.plan:
        missing = [s["name"] for s in steps if s["eta"]["p50_seconds"] is None]
        eta = {"status": "insufficient_history", "p50_seconds": None, "upper_seconds": None,
               "steps_covered": len(steps) - len(missing), "steps_total": len(steps), "missing_steps": missing}
        if not missing:
            serial = [s for s in steps if args.mode == "chain" or s["fanin"]]
            parallel = [s for s in steps if s not in serial]
            values = {}
            for key, name in (("p50_seconds", "p50_seconds"), ("p90_seconds", "upper_seconds")):
                lanes = [0.0] * min(args.maxpar, max(1, len(parallel)))
                for step in parallel:
                    i = min(range(len(lanes)), key=lanes.__getitem__)
                    lanes[i] += step["eta"][key]
                values[name] = round(max(lanes) + sum(s["eta"][key] for s in serial), 1)
            eta.update(status="schedule_heuristic", **values)
    codex_predictions = []
    plan = quotas.get("codex", {}).get("plan_type")
    for step in steps:
        if step["backend"] == "codex":
            tip = estimate_quota.forecast(samples, step["model"], step["effort"], plan, now)
            step["quota_forecast"] = tip
            codex_predictions.append(tip)
    quota_forecast = estimate_quota.aggregate(codex_predictions) if codex_predictions else {"status": "unsupported"}
    result = {"schema": 3, "mode": args.mode, "generated_at": now, "eta": eta, "steps": steps, "quotas": quotas,
              "quota_forecast": quota_forecast, "deadline_epoch": args.deadline, "task_class": steps[0]["task_class"] if not args.plan else args.task_class,
              "decision": policy(quotas, args.deadline, eta, time.time(), quota_forecast)}
    if attempt_id:
        result.update(attempt_id=attempt_id, claude_meter_tracked=tracked)
    if args.output:
        write(args.output, result)
    if args.format == "json":
        emit(result)
    else:
        render(result, markup=args.format == "html")


def render_codex_card(data, notices):
    """Telegram view only; the JSON contract and admission policy stay unchanged."""
    def esc(value):
        return html.escape(str(value), quote=False)

    def number(value):
        return f"<b><i>{value}</i></b>"

    def duration(seconds, upper=False):
        if seconds < 60:
            return f"{max(1, math.ceil(seconds) if upper else round(seconds))} с"
        minutes = math.ceil(seconds / 60) if upper else math.floor(seconds / 60 + .5)
        hours, minutes = divmod(minutes, 60)
        return f"{hours} год {minutes:02d} хв" if hours else f"{minutes} хв"

    eta, steps = data["eta"], data["steps"]
    is_plan = data.get("mode") in ("chain", "swarm") or len(steps) > 1
    title = {"chain": "ланцюг", "swarm": "рій"}.get(data.get("mode"), "ран")
    card = [f"<b>⏱ {title} · прогноз часу</b>"]
    groups = collections.Counter((s["backend"], s["model"], s.get("effort")) for s in steps)
    for (backend, model, effort), count in list(groups.items())[:4]:
        name = f"{backend} · {str(model)[:80]}"
        if effort:
            effort_label = {"none": "без міркування", "minimal": "мінімальний",
                            "low": "низький", "medium": "середній", "high": "високий",
                            "xhigh": "дуже високий", "max": "максимальний"}.get(effort, effort)
            name += f" · {str(effort_label)[:32]}"
        card.append(esc(name) + (f" ×{number(count)}" if count > 1 else ""))
    if len(groups) > 4:
        card.append(f"… ще {number(len(groups) - 4)} конфіг.")
    if is_plan:
        card.append(f"кроків: {number(len(steps))}")
    card.append("")
    if eta["p50_seconds"] is not None:
        upper = eta.get("p90_seconds", eta.get("upper_seconds"))
        label = "орієнтовний час плану" if is_plan else "орієнтовний час"
        line = f"{label}: {number(duration(eta['p50_seconds']))}"
        if upper is not None:
            line += f" · максимум {number(duration(upper, upper=True))}"
        card.append(line)
    elif "steps_covered" in eta:
        card.append(f"<b>час плану н/д · є історія для {number(eta['steps_covered'])}/{number(eta['steps_total'])} кроків</b>")
        missing = eta.get("missing_steps", [])
        if missing:
            card.append("без прогнозу часу · " + esc(", ".join(str(x)[:60] for x in missing[:5]))
                        + (f" · +{len(missing)-5}" if len(missing) > 5 else ""))
    else:
        card.append("<b>час поки невідомий</b>")

    tip = data.get("quota_forecast") or {}
    forecasts = tip.get("windows", {})
    names = {"5h": "5 год", "7d": "7 днів"}
    quotas = data.get("quotas", {})
    backends = list(quotas)
    if tip.get("backend") == "codex" and "codex" not in quotas:
        backends.append("codex")
    for backend in backends:
        quota = quotas.get(backend, {})
        if backend == "codex":
            suffix = " codex" if len(backends) > 1 else ""
            card.extend(["", f"<b>🔋 {title} · прогноз</b> лімітів{suffix}"])
        else:
            card.extend(["", f"<b>◈ {esc(backend)} · вільний ліміт</b>"])
        for key in WINDOWS:
            w = quota.get("windows", {}).get(key, {})
            p = w.get("used_percent")
            f = forecasts.get(key, {}) if backend == "codex" else {}
            usable = w.get("usable") and p is not None
            left = max(0, 100-p) if usable else None
            balance = f"{left:g}%" if usable else "неактуально" if p is not None else "немає даних"
            window_label = number(names[key].split(" ", 1)[0]) + " " + names[key].split(" ", 1)[1]
            line = f"{window_label}: " + (number(balance) if usable else f"<b>{balance}</b>")
            if "typical_pp" in f:
                typical, reserve = f["typical_pp"], f["planning_upper_pp"]
                line = f"{window_label}: {number(f'{typical:g}%')}"
                if usable:
                    line += f" ({left:g}% → {max(0, left-typical):.10g}%)"
                line += f" · максимум {number(f'{reserve:g}%')}"
                if usable:
                    line += f" ({left:g}% → {max(0, left-reserve):.10g}%)"
                else:
                    line += f" · залишок: {balance}"
                if usable and reserve >= left:
                    line += " ⚠ може не вистачити"
            else:
                if backend == "codex":
                    line += " · прогноз н/д"
            card.append(line)
    card = ["<blockquote expandable>", *card, "</blockquote>"]
    if notices:
        action = data["decision"]["action"]
        heading = "запуск відкладено" if action == "defer" else "запуск заблоковано" if action == "block" else "увага"
        card.extend(["", f"<b>⚠ {heading}</b>", *("• " + esc(n[:1].lower() + n[1:]) for n in notices)])
    print("\n".join(card))


def render(data, markup=True):
    eta = data["eta"]
    label = " · ".join(f"{s['backend']}/{s['model']}" + (f" · {s['effort']}" if s["effort"] else "")
                       for s in data["steps"][:3])
    if len(data["steps"]) > 3:
        label += f" · +{len(data['steps']) - 3}"
    eta_lines, quota_lines, forecast_lines, notices = [], [], [], []
    forecast_title = None
    eta_basis = None
    plain_note = []
    if eta["p50_seconds"] is None:
        if "steps_covered" in eta:
            eta_lines.append(f"ETA плану н/д · є історія для {eta['steps_covered']}/{eta['steps_total']} кроків")
            missing = eta["missing_steps"]
            eta_lines.append("Без ETA · " + ", ".join(missing[:5]) + (f" · +{len(missing)-5}" if len(missing) > 5 else ""))
        else:
            eta_lines.append("ETA н/д · історія " + str(eta["n"] if "n" in eta else sum(s["eta"]["n"] for s in data["steps"])))
    else:
        upper = eta.get("p90_seconds", eta.get("upper_seconds"))
        eta_basis = f"n={eta['n']}" if "n" in eta else "сума/розклад кроків"
        eta_lines.append(f"ETA {eta['p50_seconds']/60:.1f} хв · верх {upper/60:.1f} хв")
    for backend, q in data["quotas"].items():
        windows = []
        for key in WINDOWS:
            w = q["windows"][key]
            p = w["used_percent"]
            windows.append(f"{key} {p:g}%" + ("" if w["usable"] else " (неактуально)") if p is not None else f"{key} н/д")
        quota_lines.append(f"{backend} " + " · ".join(windows) + " · " + q["source"])
        if q.get("probe_status"):
            messages = {"independent": "Claude · окремий відлік до рану",
                        "throttled": "Claude · відлік пропущено через частоту запитів",
                        "probe_unavailable": "Claude · провайдер не повернув окремий відлік",
                        "control_unavailable": "Claude · контроль відліків недоступний"}
            quota_lines.append(messages[q["probe_status"]])
    tip = data.get("quota_forecast") or {}
    if tip.get("backend") == "codex":
        parts = []
        for key, window in tip["windows"].items():
            if "typical_pp" in window:
                typical = f"≈{window['typical_pp']:g}" if window["typical_pp"] >= 1 else "<1"
                basis = {"model": "модель", "model_effort": "модель і рівень міркування", "sum_of_steps": "мін. на крок"}[window["basis"]]
                parts.append(f"{key} {typical}, верх {window['planning_upper_pp']} в.п. ({basis}: n={window['n']})")
            elif "steps_covered" in window:
                parts.append(f"{key} · є дані для {window['steps_covered']}/{tip['steps']} кроків")
            else:
                parts.append(f"{key} · {window['n']}/{estimate_quota.MIN_SAMPLES} вимірів")
        if parts:
            forecast_title = "Квота Codex · сума кроків" if "steps" in tip else "Прогноз зміни квоти Codex"
            forecast_lines = parts
        else:
            forecast_lines.append("Оцінка витрат Codex недоступна · провайдер не підтвердив тариф")
    elif any(step["backend"] == "claude" for step in data["steps"]):
        plain_note.append("Для Claude показано поточну квоту")
    if data["decision"]["action"] != "allow":
        descriptions = {"quota_unavailable": "поточна квота недоступна", "codex_provider_denied": "Codex призупинив звичайні запуски",
                        "current_quota_high": "залишок квоти малий", "deadline_at_risk": "ризик вийти за дедлайн",
                        "deadline_elapsed": "вказаний дедлайн минув",
                        "forecast_quota_at_risk": "за верхньою оцінкою можливе вичерпання квоти"}
        reasons = data["decision"].get("warnings", [data["decision"]["reason"]])
        notices.extend(descriptions.get(reason, reason) for reason in reasons)
    retry_at = data["decision"].get("retry_at")
    if retry_at:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        stamp = datetime.fromtimestamp(retry_at, ZoneInfo("Europe/Kyiv"))
        notices.append("Повтор після " + stamp.strftime("%d.%m %H:%M") + " за Києвом")
    if not markup:
        if eta_basis:
            eta_lines[0] += f" · {eta_basis}; попередньо"
        forecast = ([forecast_title] if forecast_title else []) + forecast_lines
        print("\n".join([label, *eta_lines, *quota_lines, *forecast, *plain_note, *notices]))
        return

    if any(step["backend"] == "codex" for step in data["steps"]):
        render_codex_card(data, notices)
        return

    def escape(line):
        return html.escape(line, quote=False)

    headline, *eta_details = eta_lines
    if eta_basis:
        note = f"{eta_basis} · попередньо"
        if eta.get("sources", {}).get("mtime_proxy", 0)*2 > eta.get("n", 0):
            note += " · переважно старі часові мітки"
        if not eta.get("steps_total") and data["steps"][0].get("effort") and "effort" not in eta.get("scope", ""):
            note += " · спільна історія для різних effort"
        eta_details.insert(0, note)
    if len(data["steps"]) == 1:
        step = data["steps"][0]
        if step.get("task_class"):
            eta_details.append("Клас задачі · " + step["task_class"])
        measured = step.get("eta_shadow") or {}
        if measured.get("observed_seconds"):
            low, high = measured["observed_seconds"]
            basis = "клас задачі" if step.get("task_class") else "рівень міркування"
            eta_details.append(f"Фактичні тривалості · {low:.0f}–{high:.0f} с · n={measured['n']} · {basis}")
    card = ["<b>" + escape(headline) + "</b>", escape(label), *map(escape, eta_details)]
    if quota_lines:
        card.extend(["", "<b>Поточна квота</b>", *map(escape, quota_lines)])
    if forecast_lines:
        card.extend([""])
        if forecast_title:
            card.append("<b>" + escape(forecast_title) + "</b>")
        card.extend(map(escape, forecast_lines))
    print("<blockquote>" + "\n".join(card) + "</blockquote>")
    if notices:
        print("⚠️ " + "\n".join(map(escape, notices)))


def quota_delta(before, after, pair_issue=None):
    """Account changes measured around a run, with unknown external attribution."""
    results = {}
    for key in WINDOWS:
        if pair_issue:
            reason = pair_issue
        elif not before or not after:
            reason = "missing_snapshot"
        elif before["backend"] != after["backend"] or not before["fresh"] or not after["fresh"]:
            reason = "incompatible_snapshot"
        elif before["observed_at"] >= after["observed_at"]:
            reason = "same_or_older_snapshot"
        else:
            a, b = before["windows"][key], after["windows"][key]
            if not a["usable"] or not b["usable"]:
                reason = "window_unavailable"
            elif (a["reset_at"] is None or b["reset_at"] is None
                  or min(a["reset_at"], b["reset_at"]) <= after["observed_at"]):
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
                                "percentage_points": round(b["used_percent"] - a["used_percent"], 2),
                                "source": {"before": before.get("source"), "after": after.get("source")}}
                continue
        results[key] = {"status": "unavailable", "reason": reason}
    return results


def finalize(args):
    data = read(args.preflight)
    if not data:
        return
    if args.outcome == "blocked" and args.rc == 8:
        data["decision"] = {"action": "block", "reason": "deadline_elapsed"}
    step = data["steps"][0]
    backend = step["backend"]
    mono = args.end_ns - args.start_ns if args.start_ns and args.end_ns else None
    timed = mono is not None and mono >= 0
    fact = {}
    if timed:
        fact = codex_facts(args.run_dir, session_root()) if backend == "codex" else claude_facts(args.run_dir)
    before = data["quotas"].get(backend)
    state = state_path()
    controlled = before and before.get("probe_status")
    after = None
    overlap = None
    if timed:
        after = (measured_claude_snapshot(state / "claude-meter.sqlite3",
                                         allow_probe=controlled == "independent")
                 if controlled else snapshot(backend))
    if data.get("claude_meter_tracked"):
        try:
            overlap = claude_meter.close_attempt(state / "claude-meter.sqlite3", data["attempt_id"],
                                                 (before or {}).get("observed_at"),
                                                 (after or {}).get("observed_at"))
        except (OSError, sqlite3.Error) as error:
            print(f"Claude quota attempt close: {error}", file=sys.stderr)
    pair_issue = claude_meter.pair_issue(before, after, args.start_epoch, args.end_epoch, overlap) if controlled else None
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
              "quota_observed_delta": quota_delta(before, after, pair_issue),
              "prediction": data, "provider": fact}
    if controlled:
        record["claude_meter"] = {"local_overlap": overlap,
                                  "includes_final_probe": bool(after and after.get("probe_status") == "independent")}
    if timed and backend == "codex" and fact.get("thread_id"):
        profiles = estimate_quota.scan_sessions(session_root(), since=args.start_epoch - 120)
        record["codex_quota"] = estimate_quota.sample_attempt(record, profiles)
    write(state / "attempts" / (record["attempt_id"] + ".json"), record)
    write(args.run_dir / "attempt-v3.json", record)


def render_observation(data):
    if not data:
        return
    observed = data.get("quota_observed_delta", {})
    values = [f"{key} {w['percentage_points']:+g} в.п."
              for key, w in observed.items() if w["status"] == "account_delta"]
    if values:
        label = "Лічильник рахунку, включно з фінальним відліком" if data.get("claude_meter") else "Лічильник рахунку"
        print(label + " · " + " · ".join(values))
    elif data.get("claude_meter") and data.get("seconds") is not None:
        messages = {"missing_snapshot": "немає відліку", "incompatible_snapshot": "неактуальний відлік",
                    "same_or_older_snapshot": "повторний відлік", "independent_probe_unavailable": "немає двох незалежних відліків",
                    "probe_outside_run_edges": "відлік за межами рану", "local_overlap_unknown": "перетин невідомий",
                    "overlapping_local_attempt": "паралельний Claude-ран", "window_changed_or_unknown": "reset або невідоме вікно",
                    "window_unavailable": "лічильник вікна недоступний", "decreased": "лічильник зменшився"}
        details = [f"{key} {messages[w['reason']]}" for key, w in observed.items()]
        print("Лічильник рахунку н/д · " + " · ".join(details))


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
    p.add_argument("--task", type=pathlib.Path)
    p.add_argument("--task-class", default=os.environ.get("CC_ESTIMATE_TASK_CLASS") or None)
    p.add_argument("--fanin", action="store_true")
    p.add_argument("--claude-quota", action="store_true")
    p.add_argument("--attempt", action="store_true")
    p.add_argument("--wrapper-pid", type=int)
    p.add_argument("--output", type=pathlib.Path)
    p.add_argument("--format", choices=("json", "html", "text"), default="json")
    p = sub.add_parser("render")
    p.add_argument("preflight", type=pathlib.Path)
    p = sub.add_parser("render-observation")
    p.add_argument("attempt", type=pathlib.Path)
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
    p = sub.add_parser("quota-replay")
    p.add_argument("--details", action="store_true")
    p.add_argument("--since", type=timestamp)
    p = sub.add_parser("snapshot")
    p.add_argument("backend", choices=("codex", "claude"))
    sub.add_parser("clock")
    args = parser.parse_args()
    if args.command == "predict":
        estimate(args)
    elif args.command == "render":
        render(read(args.preflight))
    elif args.command == "render-observation":
        render_observation(read(args.attempt))
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
        attempts = merge_attempts(rows, live_rows(state_path()))
        samples, rejected = estimate_quota.build_history(attempts, session_root())
        write(state_path() / "history.json", {"schema": 3, "generated_at": time.time(), "rows": rows + claude,
                                              "codex_quota": samples})
        emit(counts | {"codex_quota_observations": len(samples), "codex_quota_rejected": rejected})
    elif args.command == "replay":
        replay(select_history(state_path()))
    elif args.command == "quota-replay":
        state = state_path()
        samples = quota_history(state, select_history(state))
        emit(estimate_quota.replay(samples, details=args.details, since=args.since))
    elif args.command == "snapshot":
        emit(snapshot(args.backend))
    else:
        print(time.monotonic_ns(), int(time.time()))


if __name__ == "__main__":
    main()
