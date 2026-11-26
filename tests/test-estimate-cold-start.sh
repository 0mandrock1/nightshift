#!/bin/sh
# Cold-start estimator fallback: unseen model, version-family predecessor, backend+effort, quota proxy.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CC_ESTIMATE_STATE="$TMP/state" CC_RUNS="$TMP/runs" PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" "$TMP" <<'PY'
import argparse, contextlib, importlib.util, io, json, sys, time
from pathlib import Path

bin_dir, tmp = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("est", bin_dir / "cc-estimate-v3.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
NOW = time.time()
DAY = 86400

COUNTER = iter(range(10**6))

def row(model, seconds, effort="high", age=1, **extra):
    finished = NOW - age * DAY
    return {"attempt_id": f"a{next(COUNTER)}", "backend": "codex", "model": model, "effort": effort, "outcome": "ok", "seconds": seconds,
            "finished_at": finished, "recorded_at": finished + 5, "model_source": "provider",
            "source": "wrapper_monotonic"} | extra

def sample(model, delta, effort="high", plan="plus", age=1, window="5h"):
    at = NOW - age * DAY
    return {"thread_id": f"{model}-{delta}-{age}-{window}-{next(COUNTER)}", "model": model, "effort": effort,
            "plan_type": plan, "started_at": at - 100, "available_at": at,
            "windows": {window: {"delta_pp": delta, "source": "wrapper"}}}

def quota_samples(model, deltas, **kw):
    return [s | {"windows": {**sample(model, d, **kw)["windows"], "7d": {"delta_pp": d / 5, "source": "wrapper"}}}
            for s, d in ((sample(model, d, **kw), d) for d in deltas)]

def predict(rows, samples=(), *, model="gpt-6.2-sol", effort="high", plan="plus", plan_file=None,
            mode="run", maxpar=2, used=30):
    state = tmp / "state"
    state.mkdir(exist_ok=True)
    (state / "history.json").write_text(json.dumps({"schema": 3, "rows": rows, "codex_quota": list(samples)}))
    def fake_snapshot(backend, option=None):
        window = {"used_percent": used, "reset_at": NOW + 7200, "duration_minutes": None, "usable": True}
        return {"backend": backend, "source": "codex-app-server", "observed_at": NOW, "fresh": True,
                "windows": {"5h": window, "7d": window | {"reset_at": NOW + 86400}},
                "plan_type": plan, "ordinary_usage_allowed": True, "probe_error": None}
    mod.snapshot = fake_snapshot
    args = argparse.Namespace(backend="codex", model=model, effort=effort, id="r", plan=plan_file, mode=mode,
                              maxpar=maxpar, deadline=None, task=None, task_class=None, fanin=False,
                              claude_quota=False, attempt=False, wrapper_pid=None, output=None, format="json")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        mod.estimate(args)
    return json.loads(out.getvalue())

def rendered(data, fmt):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        mod.render(data, markup=fmt == "html")
    return out.getvalue()

previous = [row("gpt-6.1-sol", s) for s in (600, 700, 800, 900, 1000, 1100, 1200)]
other_effort = [row("gpt-6-luna", 50, effort="low") for _ in range(12)]

# 1. Unseen GPT-6.2 model: predecessor cohort, strict telemetry stays unknown, admission is unchanged.
data = predict(previous + other_effort)
step = data["steps"][0]
assert data["eta"]["status"] == "insufficient_history" and data["eta"]["p50_seconds"] is None and data["eta"]["n"] == 0
fb = data["eta_fallback"]
assert fb == step["eta_fallback"] | {} and fb["fallback"] is True and fb["status"] == "provisional_fallback"
assert fb["basis"] == "version_family_predecessor" and fb["scope"] == "family_predecessor_effort"
assert fb["source_models"] == {"gpt-6.1-sol": 7} and fb["n"] == 7 and fb["effort"] == "high"
assert fb["p50_seconds"] == 900 and fb["p90_seconds"] == 1140 and fb["strict_exact_n"] == 0
assert fb["uncertainty"] == "cross_model_proxy" and fb["requested_model"] == "gpt-6.2-sol"
baseline_decision = data["decision"]
plain = rendered(data, "text")
assert "ETA н/д" in plain and "ETA (проксі) 15.0 хв · верх 19.0 хв" in plain and "gpt-6.1-sol ×7" in plain
assert "не історія самої моделі" in plain
card = rendered(data, "html")
assert "<b>час поки невідомий</b>" in card and "орієнтовний час (проксі):" in card and "gpt-6.1-sol ×7" in card

# Original behaviour without any fallback cohort is untouched and keeps the same decision.
bare = predict([])
assert "eta_fallback" not in bare and bare["decision"] == baseline_decision
assert rendered(bare, "html").count("орієнтовний час (проксі)") == 0

# 2. Insufficient data: too few predecessor rows and too few backend+effort rows -> no-data status.
few = predict([row("gpt-6.1-sol", 600) for _ in range(4)] + [row("gpt-6-luna", 700) for _ in range(5)])
assert "eta_fallback" not in few and "eta_fallback" not in few["steps"][0]
assert few["eta"]["status"] == "insufficient_history"

# 3. Exact-model history has priority and is never replaced by a proxy.
exact = predict(previous + [row("gpt-6.2-sol", s) for s in (100, 110, 120, 130, 140)])
assert exact["eta"]["status"] == "provisional" and exact["eta"]["p50_seconds"] == 120 and exact["eta"]["n"] == 5
assert "eta_fallback" not in exact and "eta_fallback" not in exact["steps"][0]

# 4. Effort / tier mismatch: no family cohort; backend+effort needs 10 rows and names every model.
medium_prev = [row("gpt-6.1-sol", s, effort="medium") for s in (600, 700, 800, 900, 1000, 1100)]
assert "eta_fallback" not in predict(medium_prev)
wrong_tier = [row("gpt-6.1-luna", 100) for _ in range(8)] + [row("gpt-6-luna", 100) for _ in range(4)]
tier = predict(wrong_tier)["eta_fallback"]
assert tier["basis"] == "backend_effort" and tier["scope"] == "backend_effort" and tier["n"] == 12
assert tier["source_models"] == {"gpt-6.1-luna": 8, "gpt-6-luna": 4}
mixed = predict([row("gpt-6.1-sol", 600) for _ in range(3)] + [row("gpt-6-luna", 700) for _ in range(8)])["eta_fallback"]
assert mixed["basis"] == "backend_effort" and mixed["source_models"] == {"gpt-6.1-sol": 3, "gpt-6-luna": 8}

# 5. Evidence hygiene: stale, failed, unverified, future-recorded and proxy-clock rows never count.
bad = ([row("gpt-6.1-sol", 600, age=90) for _ in range(3)] + [row("gpt-6.1-sol", 600, outcome="fail") for _ in range(3)]
       + [row("gpt-6.1-sol", 600, model_source="resolved_only") for _ in range(3)]
       + [row("gpt-6.1-sol", 600, recorded_at=NOW + 60) for _ in range(3)])
assert "eta_fallback" not in predict(bad + previous[:4])
recent_first = [row("gpt-6.1-sol", 100, age=50) for _ in range(30)] + [row("gpt-6.1-sol", 900, age=2) for _ in range(24)]
assert predict(recent_first)["eta_fallback"]["p50_seconds"] == 900

# 6. Quota: separate same-plan proxy samples, labelled and never authoritative.
prev_q = quota_samples("gpt-6.1-sol", (9, 10, 11, 11, 13))
data = predict(previous, prev_q)
window = data["quota_forecast"]["windows"]["5h"]
assert data["quota_forecast"]["status"] == "insufficient_history"
assert window["basis"] == "predecessor_family_proxy" and window["proxy_typical_pp"] == 11 and window["proxy_upper_pp"] == 14
assert "typical_pp" not in window and "planning_upper_pp" not in window and window["source_models"] == ["gpt-6.1-sol"]
assert data["quota_forecast"]["proxy"] == {"status": "historical_proxy", "authoritative": False,
                                           "shared_account_quota": True, "source_models": ["gpt-6.1-sol"]}
assert data["steps"][0]["quota_forecast"] == data["quota_forecast"]
# A proxy larger than the remaining balance does not change admission.
assert predict(previous, prev_q, used=95)["decision"] == predict(previous, [], used=95)["decision"]
assert "forecast_quota_at_risk" not in json.dumps(predict(previous, prev_q, used=95)["decision"])
text = rendered(data, "text")
assert "5h проксі ≈11, орієнтир верху 14 в.п. (n=5)" in text and "паралельні рани ділять одну квоту" in text
card = rendered(data, "html")
assert "проксі" in card and "максимум" not in card and "не гарантія" in card and "ділять одну квоту" in card
# Exact-model samples win; stale, other-plan, other-effort, too few and missing-plan data give none.
exact_q = quota_samples("gpt-6.2-sol", (1, 1, 2, 2, 3))
assert "typical_pp" in predict(previous, prev_q + exact_q)["quota_forecast"]["windows"]["5h"]
assert "proxy" not in predict(previous, prev_q + exact_q)["quota_forecast"]
assert "proxy" not in predict(previous, quota_samples("gpt-6.1-sol", (9, 10, 11, 11, 13), age=70))["quota_forecast"]
assert "proxy" not in predict(previous, quota_samples("gpt-6.1-sol", (9, 10, 11, 11, 13), plan="pro"))["quota_forecast"]
assert "proxy" not in predict(previous, quota_samples("gpt-6.1-sol", (9, 10, 11, 11, 13), effort="medium"))["quota_forecast"]
assert "proxy" not in predict(previous, prev_q[:4])["quota_forecast"]
assert "proxy" not in predict(previous, quota_samples("gpt-6-luna", (9, 10, 11, 11, 13)))["quota_forecast"]
no_plan = predict(previous, prev_q, plan=None)
assert no_plan["quota_forecast"]["reason"] == "plan_unavailable" and "proxy" not in no_plan["quota_forecast"]
assert predict(previous, prev_q, effort="medium")["steps"][0]["eta"]["status"] == "insufficient_history"

# 7. Mixed chain / swarm: schedule uses exact where it exists and the proxy elsewhere.
luna = [row("gpt-6-luna", s, effort="high") for s in (100, 110, 120, 130, 140, 150)]
luna_q = quota_samples("gpt-6-luna", (1, 2, 2, 3, 3))
plan_file = tmp / "plan.tsv"
plan_file.write_text("a|-|a.md|gpt-6-luna|codex\nb|-|b.md|gpt-6.2-sol|codex\n")
chain = predict(luna + previous, luna_q + prev_q, mode="chain", plan_file=plan_file)
assert chain["eta"]["status"] == "insufficient_history" and chain["eta"]["missing_steps"] == ["b"]
cf = chain["eta_fallback"]
assert cf["basis"] == "schedule_heuristic" and cf["fallback_steps"] == ["b"] and cf["source_models"] == {"gpt-6.1-sol": 7}
assert cf["p50_seconds"] == 125 + 900 and cf["upper_seconds"] > cf["p50_seconds"]
qw = chain["quota_forecast"]["windows"]["5h"]
assert qw["basis"] == "sum_of_steps_proxy" and qw["proxy_steps"] == 1 and "planning_upper_pp" not in qw
assert chain["quota_forecast"]["proxy"]["authoritative"] is False
assert "проксі" in rendered(chain, "html") and "плану (проксі)" in rendered(chain, "html")
swarm_file = tmp / "swarm.tsv"
swarm_file.write_text("a|a.md|-|gpt-6-luna|-|codex\nb|b.md|-|gpt-6.2-sol|-|codex\nc|c.md|-|gpt-6.2-sol|-|codex\n")
swarm = predict(luna + previous, luna_q + prev_q, mode="swarm", plan_file=swarm_file, maxpar=3)
assert swarm["eta_fallback"]["fallback_steps"] == ["b", "c"] and swarm["eta_fallback"]["p50_seconds"] == 900
assert swarm["quota_forecast"]["windows"]["5h"]["proxy_steps"] == 2
# A step with no defensible cohort leaves the whole plan without a proxy.
plan_file.write_text("a|-|a.md|gpt-6-luna|codex\nb|-|b.md|gpt-6.2-sol|codex\n")
partial = predict(luna, luna_q, mode="chain", plan_file=plan_file)
assert "eta_fallback" not in partial and "proxy" not in partial["quota_forecast"]
assert partial["quota_forecast"]["windows"]["5h"] == {"steps_covered": 1}

# 8. Strict telemetry schema is additive: replay/forecast of the exact model ignores the fallback.
assert mod.forecast(previous, "codex", "gpt-6.2-sol", "high", NOW)["n"] == 0
assert mod.estimate_eta.predecessors("codex", "gpt-6.1-sol") == ()
assert mod.estimate_eta.fallback(previous, "claude", "gpt-6.2-sol", "high", NOW) is None
assert mod.estimate_eta.fallback(previous, "codex", "gpt-6.2-sol", None, NOW) is None
PY
echo 'OK: cold-start ETA fallback, quota proxy, strict telemetry separation, admission unchanged'
