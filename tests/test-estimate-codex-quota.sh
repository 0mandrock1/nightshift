#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$HERE/../lib" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from estimate_quota import aggregate, forecast, replay, sample_attempt

def rate(used, reset=1300, weekly_reset=9000, plan="plus"):
    return {"limit_id": "codex", "plan_type": plan,
            "primary": {"used_percent": used, "resets_at": reset, "window_minutes": 300},
            "secondary": {"used_percent": 35, "resets_at": weekly_reset, "window_minutes": 10080}}

def snapshot(clock, used):
    return {"backend": "codex", "fresh": True, "source": "codex-app-server", "observed_at": clock,
            "plan_type": "plus", "windows": {"5h": {"used_percent": used, "reset_at": 1300, "usable": True}}}

run = {"backend": "codex", "model": "gpt-6-luna", "effort": "high", "outcome": "fail",
       "started_at": 1000, "finished_at": 1100, "recorded_at": 1110, "provider": {"thread_id": "run"},
       "quota_before": snapshot(997, 9), "quota_after": snapshot(1104, 14)}
profile = {"account": "account", "ranges": [(1000, 1100)], "points": [(1005, rate(10)), (1095, rate(12, 1301))]}
other = {"account": "unknown-different", "ranges": [(1010, 1020)], "points": []}
assert sample_attempt(run, {"run": profile, "other": other})["windows"]["5h"]["delta_pp"] == 5
assert sample_attempt(run, {"run": profile, "other": other | {"account": None}})["reason"] == "overlapping_local_session"
assert sample_attempt(run, {"run": profile, "other": other | {"account": "account"}})["reason"] == "overlapping_local_session"
# A short run can have one in-session counter event and two valid wrapper reads.
one_point = profile | {"points": profile["points"][:1]}
assert sample_attempt(run, {"run": one_point})["windows"]["5h"]["source"] == "wrapper"
assert sample_attempt(run, {"run": one_point})["attribution"] == "unknown"
edge_overlap = other | {"account": "account", "ranges": [(996, 999)]}
assert "windows" not in sample_attempt(run, {"run": one_point, "other": edge_overlap})
crossing_snapshot = snapshot(1104, 14)
crossing_snapshot["windows"]["5h"]["reset_at"] = 1500
crossing = run | {"quota_after": crossing_snapshot}
assert "5h" not in sample_attempt(crossing, {"run": profile})["windows"]
no_wrapper = {k: v for k, v in run.items() if not k.startswith("quota_")}
same = sample_attempt(no_wrapper, {"run": profile})
assert same["windows"]["5h"] == {"delta_pp": 2, "source": "session", "observed_at": 1095}
reset = profile | {"points": [(1005, rate(100, 1080)), (1095, rate(2, 1400))]}
assert "5h" not in sample_attempt(no_wrapper, {"run": reset})["windows"]

samples = []
for i, cost in enumerate((0, 0, 1, 1, 0, 5)):
    samples.append({"thread_id": str(i), "model": "gpt-6-luna", "plan_type": "plus",
                    "effort": "high" if i == 5 else "low", "started_at": (i+1)*10,
                    "available_at": (i+1)*10 + 1,
                    "windows": {"5h": {"delta_pp": cost, "source": "wrapper"}}})
result = forecast(samples, "gpt-6-luna", "high", "plus", 100)
assert result["status"] == "provisional" and result["windows"]["5h"]["n"] == 6
assert result["windows"]["5h"]["planning_upper_pp"] == 6
assert result["windows"]["5h"]["basis"] == "model" and result["windows"]["5h"]["effort_n"] == 1
assert forecast(samples, "gpt-6-luna", "high", "plus", 45)["status"] == "insufficient_history"
assert forecast(samples, "gpt-6-luna", "high", "pro", 100)["status"] == "insufficient_history"
assert forecast(samples, "gpt-6-luna", "low", "plus", 100)["windows"]["5h"]["basis"] == "model_effort"
assert aggregate([result, result])["windows"]["5h"]["planning_upper_pp"] == 12
assert aggregate([result, {"windows": {}}])["windows"]["5h"] == {"steps_covered": 1}
assert replay(samples)["5h"] == {"observations": 6, "with_forecast": 1, "above_planning_upper": 1}
PY
echo 'OK: Codex quota sample identity, resets, overlaps, chronology and composition'
