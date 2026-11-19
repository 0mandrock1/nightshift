"""Empirical Codex account-usage forecasts from comparable local observations."""

import collections
from datetime import datetime
import math

from estimate_history import documents

WINDOW_MINUTES = {"5h": 300, "7d": 10080}
MIN_SAMPLES = 5
MAX_EDGE_SECONDS = 120


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def timestamp(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def scan_sessions(sessions, since=None):
    """Read telemetry fields only. Account IDs are used in memory for overlap checks."""
    profiles = {}
    for path in sessions.glob("*/*/*/*.jsonl"):
        if since is not None:
            try:
                if path.stat().st_mtime < since:
                    continue
            except OSError:
                continue
        thread, account = None, None
        active, ranges, points = {}, [], []
        last_event = None
        for event in documents(path):
            content = event.get("payload")
            if not isinstance(content, dict):
                continue
            if event.get("type") == "session_meta":
                thread = content.get("id") or content.get("session_id")
                account = content.get("creator_account_id")
            if event.get("type") != "event_msg":
                continue
            clock = timestamp(event.get("timestamp"))
            if clock is None:
                continue
            last_event = clock
            kind = content.get("type")
            turn = content.get("turn_id")
            if kind == "task_started":
                active[turn] = clock
            elif kind in ("task_complete", "turn_aborted") and turn in active:
                ranges.append((active.pop(turn), clock))
            elif kind == "token_count":
                rate = content.get("rate_limits") or {}
                if rate.get("limit_id") == "codex":
                    points.append((clock, rate))
        if last_event is not None:
            ranges.extend((start, last_event) for start in active.values())
        if not ranges and points:
            ranges.append((points[0][0], points[-1][0]))
        if thread and (ranges or points):
            profiles[thread] = {"account": account, "ranges": ranges, "points": points}
    return profiles


def rate_window(point, key):
    clock, rate = point
    chunk = rate.get("primary" if key == "5h" else "secondary") or {}
    used, reset = chunk.get("used_percent"), chunk.get("resets_at")
    if numeric(used) and 0 <= used <= 100 and numeric(reset) and reset > clock and chunk.get("window_minutes") == WINDOW_MINUTES[key]:
        return clock, used, reset, rate.get("plan_type")
    return None


def wrapper_window(snapshot, key, plan_type):
    if not snapshot or snapshot.get("backend") != "codex" or snapshot.get("source") != "codex-app-server" or not snapshot.get("fresh"):
        return None
    if snapshot.get("plan_type") not in (None, plan_type):
        return None
    point = snapshot.get("windows", {}).get(key, {})
    clock, used, reset = snapshot.get("observed_at"), point.get("used_percent"), point.get("reset_at")
    if point.get("duration_minutes") not in (None, WINDOW_MINUTES[key]):
        return None
    if point.get("usable") and all(numeric(value) for value in (clock, used, reset)) and 0 <= used <= 100 and reset > clock:
        return clock, used, reset, plan_type
    return None


def pair_delta(first, last):
    if first is None or last is None:
        return None
    a_time, a_used, a_reset, a_plan = first
    b_time, b_used, b_reset, b_plan = last
    if (b_time <= a_time or b_used < a_used or abs(b_reset - a_reset) > 1
            or min(a_reset, b_reset) <= b_time or not a_plan or a_plan != b_plan):
        return None
    return round(b_used - a_used, 2)


def overlaps(profiles, thread, left, right):
    account = profiles[thread]["account"]
    return any(other != thread and (not account or not profile["account"] or profile["account"] == account)
               and any(a < right and b > left for a, b in profile["ranges"])
               for other, profile in profiles.items())


def sample_attempt(row, profiles):
    native = row.get("provider") or {}
    thread = native.get("thread_id")
    profile = profiles.get(thread)
    start, end = row.get("started_at"), row.get("finished_at")
    if not profile or not row.get("model") or row.get("model_source") == "resolved_only":
        return {"reason": "no_verified_session"}
    if not numeric(start) or not numeric(end) or end <= start or len(profile["points"]) < 2:
        return {"reason": "incomplete_meter_record"}
    points = profile["points"]
    plan = points[0][1].get("plan_type")
    if not plan or any(rate.get("plan_type") != plan for _, rate in points):
        return {"reason": "unknown_or_changed_plan"}
    if overlaps(profiles, thread, start, end):
        return {"reason": "overlapping_local_session"}
    measurements = {}
    for key in WINDOW_MINUTES:
        first, last = rate_window(points[0], key), rate_window(points[-1], key)
        value = None
        if first and last and 0 <= first[0] - start <= MAX_EDGE_SECONDS and -2 <= end - last[0] <= MAX_EDGE_SECONDS:
            value = pair_delta(first, last)
        source = "session"
        before = wrapper_window(row.get("quota_before"), key, plan)
        after = wrapper_window(row.get("quota_after"), key, plan)
        if (before and after and -2 <= start - before[0] <= MAX_EDGE_SECONDS
                and -2 <= after[0] - end <= MAX_EDGE_SECONDS
                and not overlaps(profiles, thread, before[0], after[0])):
            outer = pair_delta(before, after)
            if outer is not None:
                value, source = outer, "wrapper"
        if value is not None:
            timestamp_used = after[0] if source == "wrapper" else last[0]
            measurements[key] = {"delta_pp": value, "source": source, "observed_at": timestamp_used}
    if not measurements:
        return {"reason": "reset_or_incomplete_window"}
    return {"thread_id": thread, "model": row["model"], "effort": row.get("effort"), "plan_type": plan,
            "started_at": start, "available_at": max(end, row.get("recorded_at") or end,
                                                     *(w["observed_at"] for w in measurements.values())),
            "outcome": row.get("outcome"), "windows": measurements}


def build_history(rows, sessions):
    profiles = scan_sessions(sessions)
    samples, rejected = [], collections.Counter()
    for row in rows:
        if row.get("backend") != "codex":
            continue
        sample = sample_attempt(row, profiles)
        if sample.get("windows"):
            samples.append(sample)
        else:
            rejected[sample["reason"]] += 1
    return samples, rejected


def quantile(values, fraction):
    values = sorted(values)
    pos = (len(values) - 1) * fraction
    lo, hi = math.floor(pos), math.ceil(pos)
    return values[lo] + (values[hi] - values[lo]) * (pos - lo)


def forecast(samples, model, effort, plan, cutoff):
    result = {"backend": "codex", "status": "insufficient_history", "windows": {}}
    if not plan:
        return result | {"reason": "plan_unavailable"}
    matching = [sample for sample in samples if sample.get("model") == model
                and sample.get("plan_type") == plan and sample.get("available_at", math.inf) < cutoff
                and sample.get("available_at", 0) >= cutoff - 60 * 86400]
    for key in WINDOW_MINUTES:
        known = [sample for sample in matching if key in sample["windows"]]
        exact = [sample for sample in known if sample.get("effort") == effort] if effort else []
        basis = "model"
        if len(exact) >= MIN_SAMPLES:
            known, basis = exact, "model_effort"
        values = [sample["windows"][key]["delta_pp"] for sample in known]
        win = {"n": len(values), "basis": basis}
        if len(values) >= MIN_SAMPLES:
            upper = quantile(values, .9)
            if exact and basis == "model":
                upper = max(upper, max(sample["windows"][key]["delta_pp"] for sample in exact))
            win.update(typical_pp=round(quantile(values, .5), 1), planning_upper_pp=math.ceil(upper + 1),
                       effort_n=len(exact),
                       sources=dict(collections.Counter(sample["windows"][key]["source"] for sample in known)))
        result["windows"][key] = win
    if any("typical_pp" in w for w in result["windows"].values()):
        result["status"] = "provisional"
    return result


def aggregate(step_forecasts):
    if len(step_forecasts) == 1:
        return step_forecasts[0]
    result = {"backend": "codex", "status": "insufficient_history", "windows": {}, "steps": len(step_forecasts)}
    for key in WINDOW_MINUTES:
        valid = [s["windows"][key] for s in step_forecasts if "typical_pp" in s["windows"].get(key, {})]
        tip = {"steps_covered": len(valid)}
        if len(valid) == len(step_forecasts):
            tip.update(typical_pp=round(sum(w["typical_pp"] for w in valid), 1),
                       planning_upper_pp=sum(w["planning_upper_pp"] for w in valid),
                       n=min(w["n"] for w in valid), basis="sum_of_steps")
            result["status"] = "provisional"
        result["windows"][key] = tip
    return result


def replay(samples):
    by_window = {key: {"observations": 0, "with_forecast": 0, "above_planning_upper": 0} for key in WINDOW_MINUTES}
    for sample in samples:
        prediction = forecast(samples, sample["model"], sample.get("effort"), sample["plan_type"], sample["started_at"])
        for key, measure in sample["windows"].items():
            summary = by_window[key]
            summary["observations"] += 1
            upper = prediction["windows"].get(key, {}).get("planning_upper_pp")
            if upper is not None:
                summary["with_forecast"] += 1
                summary["above_planning_upper"] += measure["delta_pp"] > upper
    return by_window
