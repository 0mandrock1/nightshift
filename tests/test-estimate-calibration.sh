#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CC_RUNS="$TMP/runs" CC_ESTIMATE_STATE="$TMP/state" CC_SWARMS_DIR="$TMP/swarms"
export CC_WEEK_LOCK="$TMP/no-week-lock" CC_PG_CREDS="$TMP/no-creds"
export CC_ESTIMATE_V3=1 CC_ESTIMATE_V3_CLAUDE=1 CC_ESTIMATE_ETA_SHADOW=1 CC_ESTIMATE_CLAUDE_PROBES=0
export CC_BACKEND=claude CC_RUN_SH="$BIN/cc-run.sh" CC_NOTIFY="$TMP/notify.sh"
export CC_USAGE_CLI="$HERE/fixtures/usage-cli-stub.js"
export CC_CLAUDE_BIN="$TMP/claude" CC_CODEX_BIN="$TMP/codex" CC_CODEX_USAGE_BIN=false
export TEST_NOTIFICATIONS="$TMP/telegram.log" CODEX_HOME="$TMP/codex-home"
mkdir -p "$CC_ESTIMATE_STATE" "$CC_RUNS" "$TMP/repo"
cat > "$CC_NOTIFY" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$TEST_NOTIFICATIONS"
SH
cat > "$CC_CLAUDE_BIN" <<'SH'
#!/bin/sh
printf 'CHANGED: none\nRESULT: ok\n'
SH
cat > "$CC_CODEX_BIN" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    printf 'CHANGED: none\nRESULT: ok\n' > "$2"
    break
  fi
  shift
done
printf '{"type":"turn.completed","usage":{"output_tokens":400}}\n'
SH
chmod +x "$CC_CLAUDE_BIN" "$CC_CODEX_BIN"

PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" "$CC_ESTIMATE_STATE" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import time
from types import SimpleNamespace
from unittest.mock import patch

bin_dir, state = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("estimator", bin_dir / "cc-estimate-v3.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
from estimate_eta import candidate
import estimate_claude_meter as meter

now = time.time()
rows = [
    {"backend": backend, "model": model, "outcome": "ok", "attempt_id": f"{backend}-{i}",
     "seconds": 120, "started_at": now-400, "finished_at": now-280, "source": "wrapper_monotonic"}
    for i in range(6) for backend, model in (("claude", "sonnet"), ("codex", "gpt-6-luna"))
]
m.write(state / "history.json", {"rows": rows})
claude = rows[::2]
late = claude[0] | {"seconds": 5000, "recorded_at": now + 1}
unfinished = claude[0] | {"seconds": 5000, "finished_at": now + 1, "recorded_at": now - 1}
mixed = [late, unfinished, *rows]
assert m.forecast(mixed, "claude", "sonnet", None, now)["n"] == 6
estimate = candidate(mixed, "claude", "rare", "high", now, "rare", "fanin")
assert (estimate["scope"], estimate["n"], estimate["p90_seconds"]) == ("backend", 6, 120)
assert candidate(mixed[:5], "claude", "sonnet", None, now)["status"] == "insufficient_history"

before = {"fresh": True, "observed_at": 100, "sample_id": "a", "probe_status": "independent"}
after = before | {"observed_at": 140, "sample_id": "b"}
assert meter.pair_issue(before, after, 101, 139, False) is None
assert meter.pair_issue(before, before, 101, 139, False) == "same_or_older_snapshot"
assert meter.pair_issue(before, after | {"sample_id": "a"}, 101, 139, False) == "same_or_older_snapshot"
assert meter.pair_issue(before, after | {"probe_status": "throttled"}, 101, 139, False) == "independent_probe_unavailable"
assert meter.pair_issue(before, after, 101, 50, False) == "probe_outside_run_edges"
assert meter.pair_issue(before, after, 101, 139, True) == "overlapping_local_attempt"
assert meter.pair_issue(before, after, 101, 139, None) == "local_overlap_unknown"
for reading in (before, after):
    reading.update(backend="claude", source="live", windows={
        "5h": {"usable": True, "used_percent": 3, "reset_at": 200},
        "7d": {"usable": False, "used_percent": None, "reset_at": None},
    })
assert m.quota_delta(before, after)["5h"]["attribution"] == "unknown"
assert m.quota_delta(before, after)["7d"]["reason"] == "window_unavailable"
after["windows"]["5h"]["reset_at"] = 300
assert m.quota_delta(before, after)["5h"]["reason"] == "window_changed_or_unknown"

quota = {"windows": {"5h": {"usable": True, "used_percent": 97, "reset_at": now + 600}},
         "fresh": True, "ordinary_usage_allowed": True}
tip = {"windows": {"5h": {"planning_upper_pp": 9}}}
eta = {"p90_seconds": 120}
assert m.policy({"codex": quota}, None, eta, now, tip)["action"] == "warn"
assert m.policy({"codex": quota | {"ordinary_usage_allowed": False}}, None, eta, now, tip)["action"] == "defer"

args = SimpleNamespace(plan=None, id=None, backend="codex", model="gpt-6-luna", mode="run",
                       effort=None, claude_quota=False, task_class=None, deadline=now+1,
                       attempt=False, output=None, format="json")
with (patch.object(m, "state_path", return_value=state),
      patch.object(m.time, "time", side_effect=[now, now+2]),
      patch.object(m, "snapshot", return_value=quota),
      patch.object(m, "emit") as emit):
    m.estimate(args)
    assert emit.call_args.args[0]["decision"]["reason"] == "deadline_elapsed"


with TemporaryDirectory() as private:
    db = Path(private) / "meter.db"
    with patch.object(meter.time, "time", return_value=100):
        meter.register(db, "first", os.getpid())
        assert meter.reserve_probe(db)
    with patch.object(meter.time, "time", return_value=104):
        meter.register(db, "parallel", os.getpid())
        assert not meter.reserve_probe(db)
    with patch.object(meter.time, "time", return_value=115):
        meter.close_attempt(db, "parallel")
    with patch.object(meter.time, "time", return_value=131):
        assert meter.reserve_probe(db)
        assert meter.close_attempt(db, "first", 101, 131)
    with patch.object(meter.time, "time", return_value=162):
        meter.register(db, "isolated", os.getpid())
        assert meter.reserve_probe(db)
        assert not meter.close_attempt(db, "isolated", 162, 180)
PY

git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm init
printf 'fixture\n' > "$TMP/task.md"
printf 'claude-step|none|%s|sonnet|claude\ncodex-step|none|%s|sonnet|codex\n' \
  "$TMP/task.md" "$TMP/task.md" > "$TMP/chain"
if ! sh "$BIN/cc-chain.sh" "$TMP/repo" "$TMP/chain" calibration > "$TMP/chain.log" 2>&1; then
  cat "$TMP/chain.log"; exit 1
fi
jq -e '.eta.status == "schedule_heuristic" and .eta.upper_seconds == 240 and
  (.eta | has("p90_seconds") | not) and
  [.steps[]|[.backend,.mode]] == [["claude","chain_step"],["codex","chain_step"]]' \
  "$CC_RUNS"/calibration-*.preflight-v3.json >/dev/null
for backend in claude codex; do
  jq -e --arg b "$backend" '
    .backend==$b and .mode=="chain_step" and .outcome=="ok" and .seconds>0 and
    .prediction.steps[0].mode=="chain_step" and .prediction.steps[0].eta_shadow.p50_seconds==120
  ' "$CC_RUNS"/"$backend"-step-*/attempt-v3.json >/dev/null
done

printf 'a|%s|test -f task-proof|sonnet|none|claude\nb|%s|test -f task-proof|gpt-test-missing|none|codex\n' \
  "$TMP/task.md" "$TMP/task.md" > "$TMP/swarm"
: > "$TMP/repo/task-proof"
git -C "$TMP/repo" add task-proof
git -C "$TMP/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm verify
cp "$TMP/task.md" "$TMP/swarm.fanin"
if ! MAXPAR=2 sh "$BIN/cc-swarm.sh" "$TMP/repo" "$TMP/swarm" calibration-swarm > "$TMP/swarm.log" 2>&1; then
  cat "$TMP/swarm.log"; cat "$CC_SWARMS_DIR/calibration-swarm/manifest.tsv"; exit 1
fi
jq -e '
  (.eta|.p50_seconds==null and .steps_covered==2 and .steps_total==3 and .missing_steps==["b"]) and
  [.steps[]|[.backend,.mode]] == [["claude","lane"],["codex","lane"],["claude","fanin"]]
' "$CC_SWARMS_DIR/calibration-swarm/preflight-v3.json" >/dev/null
jq -e '.mode=="fanin" and .backend=="claude" and .outcome=="ok" and
  .prediction.steps[0].mode=="fanin"
' "$CC_RUNS/calibration-swarm-fanin/attempt-v3.json" >/dev/null
grep -q 'сума/розклад кроків' "$TEST_NOTIFICATIONS"
grep -q 'ETA плану н/д · є історія для 2/3 кроків' "$TEST_NOTIFICATIONS"
grep -q 'Без ETA · b' "$TEST_NOTIFICATIONS"
echo 'OK: as-of ETA, small samples, independent meter, overlap, mixed chain and swarm fan-in'
