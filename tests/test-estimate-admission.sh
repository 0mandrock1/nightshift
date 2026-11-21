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
