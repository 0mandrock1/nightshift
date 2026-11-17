#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CC_RUNS="$TMP/runs" CC_ESTIMATE_STATE="$TMP/state"
export CC_CODEX_USAGE_BIN="$TMP/usage" CC_CODEX_BIN="$TMP/codex-exec"
export CC_NOTIFY="$HERE/fixtures/notify-null.sh" CC_ESTIMATE_V3=1 CC_ESTIMATE_V3_ENFORCE=1

cat > "$CC_CODEX_USAGE_BIN" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
p = {"usedPercent": 100, "resetsAt": int(time.time()) + 3600}
allow = os.environ.get("TEST_ALLOW") == "true"
result = {"id": 2, "result": {"ordinaryUsageAllowed": allow,
          "rateLimits": {"primary": p}}}
for line in sys.stdin:
    if json.loads(line).get("id") == 2:
        sys.stdout.write('{"id":1,"result":{}}\n' + json.dumps(result) + "\n")
        sys.stdout.flush()
        break
PY
cat > "$CC_CODEX_BIN" <<'SH'
#!/bin/sh
touch "$CC_RUNS/incorrect-launch"
exit 91
SH
chmod +x "$CC_CODEX_USAGE_BIN" "$CC_CODEX_BIN"
mkdir -p "$CC_RUNS/partial"
printf 'fixture\n' > "$CC_RUNS/partial/task.md"

set +e
sh "$BIN/cc-run.sh" "$CC_RUNS/partial" none sonnet codex > "$TMP/output" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { cat "$TMP/output"; exit 1; }
[ ! -e "$CC_RUNS/incorrect-launch" ]
jq -e '
  .backend=="codex" and .resolved_model=="gpt-6-luna" and .outcome=="deferred" and .seconds==null and
  .prediction.decision.reason=="codex_provider_denied" and .prediction.decision.retry_at>0 and
  .quota_before.windows["7d"].used_percent==null and .quota_after==null
' "$CC_RUNS/partial/attempt-v3.json" >/dev/null
TEST_ALLOW=true python3 "$BIN/cc-estimate-v3.py" predict --backend codex --model sonnet \
  --deadline "$(($(date +%s)+1800))" | jq -e '
  .decision.action=="warn" and
  (.decision.warnings == ["quota_unavailable","current_quota_high","deadline_at_risk"])
' >/dev/null

mkdir -p "$CC_RUNS/expired"
printf 'fixture\n' > "$CC_RUNS/expired/task.md"
set +e
TEST_ALLOW=true CC_ESTIMATE_DEADLINE_EPOCH=1 sh "$BIN/cc-run.sh" "$CC_RUNS/expired" none sonnet codex > "$TMP/expired" 2>&1
rc=$?
set -e
[ "$rc" = 8 ] || { cat "$TMP/expired"; exit 1; }
[ ! -e "$CC_RUNS/incorrect-launch" ]
jq -e '.outcome=="blocked" and .prediction.decision.reason=="deadline_elapsed"' "$CC_RUNS/expired/attempt-v3.json" >/dev/null

PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN/cc-estimate-v3.py" "$TMP" <<'PY'
import importlib.util, pathlib, sys
path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("estimate", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = pathlib.Path(tmp) / "test-history"
def row(attempt, thread, finished, source="provider"):
    return {"backend": "codex", "model": "gpt-6-luna", "outcome": "ok", "model_source": source,
            "attempt_id": attempt, "provider": {"thread_id": thread}, "finished_at": finished, "seconds": 60}
historical = [row(str(i), str(i), i+1) for i in range(4)]
module.write(state / "history.json", {"rows": historical})
module.write(state / "attempts" / "a.json", row("a", "3", 4))
module.write(state / "attempts" / "b.json", row("b", "new", 10))
module.write(state / "attempts" / "c.json", row("c", "model-not-observed", 2, "resolved_only"))
rows = module.select_history(state)
assert len(rows) == 6
assert module.forecast(rows, "codex", "gpt-6-luna", None, 10)["p50_seconds"] is None
assert module.forecast(rows, "codex", "gpt-6-luna", None, 11)["p50_seconds"] == 60
assert module.forecast(rows, "claude", "gpt-6-luna", None, 11)["p50_seconds"] is None
now = 1000
w = {"used_percent": 20, "reset_at": 1200, "usable": True}
q = {"backend": "codex", "fresh": True, "observed_at": now, "windows": {"5h": w, "7d": w}}
after = q | {"observed_at": now + 1, "windows": {"5h": w | {"used_percent": 22}, "7d": w | {"reset_at": 1600}}}
assert module.quota_delta(q, after)["5h"]["percentage_points"] == 2
assert module.quota_delta(q, after)["7d"]["reason"] == "window_changed_or_unknown"
assert module.quota_delta(q, q)["5h"]["reason"] == "same_or_older_snapshot"
PY
echo 'OK: native provider guard, partial windows, alias mapping, deduplication and chronological replay'
