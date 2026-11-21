#!/bin/sh
set -eu
BIN=$(cd "$(dirname "$0")/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$BIN/cc-estimate-v3-lib.sh"
export CC_CLAUDE_PROJECTS="$TMP/sessions"
mkdir -p "$CC_CLAUDE_PROJECTS" "$TMP/run"
printf 'fixture\n' > "$TMP/run/task.md"
printf 'RESULT: ok\n' > "$TMP/run/out.log"
printf 'expected-id\n' > "$TMP/run/session_id"
printf '{"message":{"model":"claude-sonnet-test","usage":{"output_tokens":42}}}\n' > "$CC_CLAUDE_PROJECTS/other-id.jsonl"
printf '{"total_out":1}\n' > "$TMP/run/usage.json"
if sh "$BIN/run-usage.sh" "$TMP/run"; then exit 1; fi
[ ! -e "$TMP/run/usage.json" ]
test "$(find "$TMP/run" -name '.usage.previous.*' | wc -l)" -eq 1

printf '{"message":{"model":"claude-sonnet-test","usage":{"output_tokens":402}}}\n' > "$CC_CLAUDE_PROJECTS/expected-id.jsonl"
sh "$BIN/run-usage.sh" "$TMP/run"
jq -e '.total_out==402 and (.session|endswith("/expected-id.jsonl"))' "$TMP/run/usage.json" >/dev/null

printf '{"type":"init"}\n' > "$CC_CLAUDE_PROJECTS/expected-id.jsonl"
if sh "$BIN/run-usage.sh" "$TMP/run"; then exit 1; fi
[ ! -e "$TMP/run/usage.json" ]

V3_PATH="$TMP/preflight.json"
printf '{"decision":{"action":"warn","reason":"deadline_at_risk"}}\n' > "$V3_PATH"
CC_ESTIMATE_DEADLINE_EPOCH="$(($(date +%s)+60))"
if cc_v3_stop_code; then exit 1; fi
CC_ESTIMATE_DEADLINE_EPOCH="$(date +%s).0"
[ "$(cc_v3_stop_code)" = 8 ]
V3_PATH=""
[ "$(cc_v3_stop_code)" = 8 ]
CC_ESTIMATE_V3_ENFORCE=0
if cc_v3_stop_code; then exit 1; fi

echo 'OK: quota/expiry recheck, exact transcript binding, unknown token count and stale usage isolation'
PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" "$TMP" <<'PY'
import importlib.util
from pathlib import Path
import sys

bin_dir, scratch = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("est", bin_dir / "cc-estimate-v3.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
task = scratch / "labelled.md"
task.write_text("# Task class: Review\n\nRead only.\n")
assert mod.task_class_from_file(task) == "review"
plan = scratch / "plan.tsv"
plan.write_text(f"r|none|{task}|sonnet|claude\n")
assert mod.plan_steps(plan, "chain", "codex")[0][-1] == task

test_row = {"backend": "codex", "model": "gpt-6-luna", "outcome": "ok",
            "model_source": "provider", "source": "wrapper_monotonic",
            "finished_at": 1000, "recorded_at": 1001, "effort": "low", "task_class": "review"}
rows = [test_row | {"seconds": sec} for sec in (26, 30, 45)]
rows += [test_row | {"seconds": 3000, "effort": "high"},
         test_row | {"seconds": 3000, "recorded_at": 1003},
         test_row | {"seconds": 3000, "model_source": "resolved_only"}]
base = {"p50_seconds": 480, "p90_seconds": 900}
eta = mod.estimate_eta.measured_candidate(rows, "codex", "gpt-6-luna", "low", 1003, "review", base)
assert eta["p50_seconds"] == 120 and eta["p90_seconds"] == 900 and eta["n"] == 3, eta
assert mod.estimate_eta.measured_candidate(rows, "codex", "gpt-6-luna", "low", 1003, "analysis", base) is None
PY
echo 'OK: task label and measured ETA cohort'
