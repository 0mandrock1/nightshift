"""Candidate ETA from recent comparable attempts."""

import collections
import math

from estimate_quota import quantile


def model_key(backend, model):
    if backend == "claude" and model.startswith("claude-"):
        tier = model.split("-")[1]
        if tier in ("sonnet", "opus", "haiku"):
            return tier
    return model


def candidate(rows, backend, model, effort, cutoff, task_class=None, mode=None,
              *, recent=24, upper=.9, min_group=10, terminal=False):
    outcomes = {"ok", "fail", "ambiguous", "timeout", "quota", "limit"} if terminal else {"ok"}
    usable = [
        r for r in rows
        if r.get("backend") == backend and r.get("outcome") in outcomes
        and type(r.get("seconds")) in (int, float) and 0 < r["seconds"] < math.inf
        and r.get("finished_at") is not None
        and max(r["finished_at"], r.get("recorded_at") or r["finished_at"]) < cutoff
        and r.get("model") and r.get("model_source") != "resolved_only"
    ]
    usable.sort(key=lambda r: r["finished_at"], reverse=True)
    tier = model_key(backend, model)
    pools = [
        ("model", [r for r in usable if r["model"] == model]),
        ("tier", [r for r in usable if model_key(backend, r["model"]) == tier]),
        ("backend", usable),
    ]
    scope, pool = next(((scope, pool) for scope, pool in pools if len(pool) >= min_group), pools[-1])
    if scope == "backend":
        # Preserve a model-specific forecast when even the baseline has enough history.
        scope, pool = next(((s, p) for s, p in pools[:2] if len(p) >= 5), (scope, pool))
    for key, value in (("task_class", task_class), ("effort", effort), ("mode", mode)):
        if value:
            recent_pool = [r for r in pool if r.get(key) == value]
            if len(recent_pool) >= min_group:
                scope, pool = scope + "_" + key, recent_pool
    sample = pool[:recent]
    result = {"n": len(sample), "scope": scope, "status": "insufficient_history",
              "p50_seconds": None, "p90_seconds": None}
    if len(sample) >= 5:
        values = [r["seconds"] for r in sample]
        result.update(status="provisional",
                      p50_seconds=round(quantile(values, .5), 1),
                      p90_seconds=round(quantile(values, upper), 1),
                      sources=dict(collections.Counter(r.get("source", "unknown") for r in sample)))
    return result
