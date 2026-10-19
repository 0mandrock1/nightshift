#!/bin/sh
# Codex usage must never inherit a previous Claude attempt in the same run-dir.
set -eu
BIN=$(cd "$(dirname "$0")/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$BIN/cc-util-lib.sh"
printf '{"total_out":0}\n' > "$TMP/usage.json"
printf '{"type":"turn.completed","usage":{"output_tokens":75644}}\n' > "$TMP/events.jsonl"
ACTUAL=$(cc_out_tokens "$TMP" codex)
[ "$ACTUAL" = 75644 ] || { echo "FAIL: stale Claude usage won: $ACTUAL"; exit 1; }
[ "$(cc_out_tokens "$TMP" claude)" = 0 ] || exit 1
printf 'CHANGED: app.js\nRESULT: ok\n' > "$TMP/out.log"
if cc_no_work_guard "$TMP" codex; then echo 'FAIL: real Codex work rejected'; exit 1; fi
rm "$TMP/events.jsonl"
[ -z "$(cc_out_tokens "$TMP" codex)" ] || { echo 'FAIL: Codex fell back to Claude usage'; exit 1; }
echo 'OK: backend-specific usage; stale Claude zero cannot reject Codex work'
