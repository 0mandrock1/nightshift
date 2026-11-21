#!/usr/bin/env python3
"""Evaluate ETA against a frozen snapshot and a previously fixed time split."""

import argparse
import collections
import importlib.util
import json
import math
from pathlib import Path
import statistics
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "nightshift_estimator", Path(__file__).with_name("cc-estimate-v3.py")
)
estimator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(estimator)
from estimate_eta import candidate
from estimate_history import artifact_times, claude_run_records


def available_at(row, imported_at=None):
    finished = row.get("finished_at")
    if finished is None:
        return math.inf
    return max(finished, row.get("recorded_at") or imported_at or finished)


def launch_features(row):
    prediction = row.get("prediction") or {}
    step = (prediction.get("steps") or [{}])[0]
    if step.get("model"):
        return step["model"], step.get("effort") or None, prediction.get("task_class"), step.get("mode") or row.get("mode")
    if row["backend"] == "claude":
        # Legacy telemetry records the tier as a proxy for the launch alias.
        return row.get("tier") or row["model"], None, None, None
    # No preflight artifact. Native turn_context supplies launch-config proxies.
    return row["model"], row.get("effort"), None, None


def metrics(entries, field):
    valid = [r for r in entries if (r[field] or {}).get("p90_seconds") is not None]
    result = {"n": len(entries), "with_eta": len(valid)}
    if not valid:
        return result
    residuals = [r["actual"] - r[field]["p50_seconds"] for r in valid]
    upper_errors = [r["actual"] - r[field]["p90_seconds"] for r in valid]
    misses = sum(e > 0 for e in upper_errors)
    p = misses / len(valid)
    z = 1.96
    center = (p + z*z/(2*len(valid))) / (1 + z*z/len(valid))
    radius = z * math.sqrt(p*(1-p)/len(valid) + z*z/(4*len(valid)**2)) / (1 + z*z/len(valid))
    return result | {
        "above": misses,
        "above_fraction": round(p, 3),
        "above_fraction_wilson95": [round(max(0, center-radius), 3), round(min(1, center+radius), 3)],
        "mae": round(statistics.mean(map(abs, residuals)), 1),
        "medae": round(statistics.median(map(abs, residuals)), 1),
        "mean_signed_error_actual_minus_typical": round(statistics.mean(residuals), 1),
        "pinball": round(statistics.mean(max(.9*e, -.1*e) for e in upper_errors), 1),
        "mean_width_p90_minus_p50": round(statistics.mean(
            r[field]["p90_seconds"] - r[field]["p50_seconds"] for r in valid), 1),
    }


def group(entries, field):
    values = collections.defaultdict(list)
    for row in entries:
        values[row[field]].append(row)
    return {key: metrics(items, "baseline") for key, items in sorted(values.items())}


def case(row):
    keys = ("run_id", "source", "actual", "model", "effort", "mode", "outcome", "baseline")
    return {key: row[key] for key in keys}


def diagnostics(data):
    scored = [r for r in data if r["baseline"]["p50_seconds"] is not None]
    ordered = sorted(scored, key=lambda r: r["actual"] - r["baseline"]["p50_seconds"])
    upper = sorted(scored, key=lambda r: r["actual"] - r["baseline"]["p90_seconds"], reverse=True)
    return {
        "by_source_all_terminal": group(data, "source"),
        "by_outcome": group(data, "outcome"),
        "by_source_ok": group([r for r in data if r["outcome"] == "ok"], "source"),
        "by_duration_ok": group([r for r in data if r["outcome"] == "ok"], "bucket"),
        "largest_overestimates": [case(r) for r in ordered[:3] if r["actual"] < r["baseline"]["p50_seconds"]],
        "largest_underestimates": [case(r) for r in ordered[-3:][::-1] if r["actual"] > r["baseline"]["p50_seconds"]],
        "largest_upper_misses": [case(r) for r in upper[:3] if r["actual"] > r["baseline"]["p90_seconds"]],
    }


def freeze_availability(state, runs):
    history = estimator.read(state / "history.json", {}) or {}
    db = {r["run_id"]: r for r in claude_run_records(runs)}
    result = {}
    for row in history.get("rows", []):
        path = runs / row["run_id"]
        if path.parent != runs:
            continue
        names = ("events.jsonl", "exit_code")
        stamps = [row["finished_at"]]
        if row["backend"] == "claude":
            names = ("usage.json", "session_id", "exit_code")
            record = db.get(row["run_id"])
            if record and all(record[k] == row[k] for k in ("finished_at", "seconds", "outcome")):
                stamps.append(record["recorded_at"])
            else:
                # There is no earlier proof of this version of the row.
                stamps.append(history["generated_at"])
        result[row["attempt_id"]] = max(stamps + artifact_times(path, names))
    return result


def data_for(state, cutoffs, strict_imported=False, trust_legacy_effort=True, availability=None):
    history = estimator.read(state / "history.json", {}) or {}
    imported_at = history.get("generated_at") if strict_imported else None
    availability = availability or {}
    imported = [r | {"recorded_at": max(available_at(r, imported_at), imported_at or 0,
                                       availability.get(r["attempt_id"], 0))}
                for r in history.get("rows", [])]
    live = list(estimator.live_rows(state))
    merged = estimator.merge_attempts(imported, live)
    output = collections.defaultdict(list)
    for row in merged:
        started, actual = row.get("started_at"), row.get("seconds")
        if not started or not actual or actual <= 0:
            continue
        backend = row["backend"]
        if backend not in cutoffs:
            continue
        cutoff = (row.get("prediction") or {}).get("generated_at") or started
        # Second-resolution launch timestamps can round down before the preflight.
        cutoff = min(started, cutoff)
        model, effort, task_class, mode = launch_features(row)
        if not trust_legacy_effort and not row.get("prediction"):
            effort = None
        known = estimator.merge_attempts(
            (r for r in imported if available_at(r, imported_at) < cutoff),
            (r for r in live if available_at(r) < cutoff),
        )
        baseline = estimator.forecast(known, backend, model, effort, cutoff, task_class)
        source = "provider_timestamps" if row["source"] == "codex_session" else row["source"]
        bucket = "1 ≤5 хв" if actual <= 300 else "2 5–15 хв" if actual <= 900 else "3 >15 хв"
        outcome = "quota" if row["outcome"] == "limit" else row["outcome"]
        output[backend].append({
            "run_id": row["run_id"], "cutoff": cutoff, "holdout": started >= cutoffs[backend],
            "backend": backend, "actual": actual, "model": model, "effort": effort,
            "task_class": task_class, "mode": mode, "source": source, "bucket": bucket,
            "outcome": outcome, "known": known, "baseline": baseline,
        })
    return output


def evaluate(rows, config, *, terminal=False, features=("task_class", "mode", "effort")):
    scored = [
        row | {"candidate": candidate(
            row["known"], row["backend"], row["model"], row["effort"] if "effort" in features else None,
            row["cutoff"], row["task_class"] if "task_class" in features else None,
            row["mode"] if "mode" in features else None, terminal=terminal, **config)}
        for row in rows
    ]
    paired = [r for r in scored if r["baseline"]["p90_seconds"] is not None
              and r["candidate"]["p90_seconds"] is not None]
    return {
        "baseline_all": metrics(scored, "baseline"),
        "candidate_all": metrics(scored, "candidate"),
        "paired_baseline": metrics(paired, "baseline"),
        "paired_candidate": metrics(paired, "candidate"),
        "candidate_scopes": dict(collections.Counter(r["candidate"]["scope"] for r in scored)),
    }


def tune(rows):
    grid = []
    for recent in (12, 24, 48, None):
        for upper in (.90, .95):
            config = {"recent": recent, "upper": upper}
            result = evaluate(rows, config)
            b, c = result["paired_baseline"], result["paired_candidate"]
            # Compare on the intersection, protect coverage and set a width budget.
            eligible = (c["with_eta"] > 0
                        and result["candidate_all"]["with_eta"] >= result["baseline_all"]["with_eta"]
                        and c["mean_width_p90_minus_p50"] <= b["mean_width_p90_minus_p50"] * 1.25)
            score = (c["mae"] + 2*c["pinball"] + 1000*abs(c["above_fraction"] - .1)) if eligible else None
            grid.append({"config": config, "score": score, "train": result})
    ranked = [r for r in grid if r["score"] is not None]
    return {"selected": min(ranked, key=lambda r: r["score"])["config"] if ranked else None, "grid": grid}


def comparison(rows, config):
    success = [r for r in rows if r["outcome"] == "ok"]
    return {
        "success": evaluate(success, config),
        "success_by_source": {s: evaluate([r for r in success if r["source"] == s], config)
                              for s in sorted({r["source"] for r in success})},
        "terminal_with_success_history": evaluate(rows, config),
        "terminal_with_terminal_history": evaluate(rows, config, terminal=True),
        "holdout_by_terminal_outcome": {
            o: evaluate([r for r in rows if r["outcome"] == o], config, terminal=True)
            for o in sorted({r["outcome"] for r in rows})
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--split", type=Path, required=True)
    parser.add_argument("--strict-imported", action="store_true")
    parser.add_argument("--no-legacy-effort", action="store_true")
    parser.add_argument("--availability", type=Path)
    parser.add_argument("--freeze-availability", type=Path, metavar="RUNS")
    parser.add_argument("--tune", action="store_true")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    if args.freeze_availability:
        print(json.dumps(freeze_availability(args.state, args.freeze_availability), sort_keys=True))
        return
    cutoffs = json.loads(args.split.read_text())["cutoffs"]
    availability = json.loads(args.availability.read_text()) if args.availability else None
    data = data_for(args.state, cutoffs, args.strict_imported, not args.no_legacy_effort, availability)
    result = {}
    selected = json.loads(args.config.read_text()) if args.config else {}
    for backend, rows in data.items():
        train = [r for r in rows if not r["holdout"] and r["outcome"] == "ok"]
        if args.tune:
            result[backend] = tune(train)
            continue
        if args.config:
            config = selected[backend]["selected"]
            if config is None:
                result[backend] = {"status": "no_train_candidate"}
                continue
            result[backend] = comparison([r for r in rows if r["holdout"]], config)
            result[backend]["training_feature_checks"] = {
                feature: evaluate(train, config, features=tuple(
                    f for f in ("task_class", "mode", "effort") if f != feature))
                for feature in ("task_class", "mode", "effort")
            }
            continue
        result[backend] = {
            split: diagnostics([r for r in rows if r["holdout"] == holdout])
            for split, holdout in (("train", False), ("holdout", True))
        }
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
