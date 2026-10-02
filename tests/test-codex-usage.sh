#!/bin/sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/codex"
cat > "$FAKE" <<'EOF_FAKE'
#!/usr/bin/env python3
import json,sys
for line in sys.stdin:
    try: obj=json.loads(line)
    except Exception: continue
    if obj.get("id")==1:
        print(json.dumps({"id":1,"result":{"userAgent":"stub"}}), flush=True)
    elif obj.get("id")==2:
        print(json.dumps({"id":2,"result":{"ordinaryUsageAllowed":True,"rateLimits":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1},"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":2},"planType":"plus"}}}), flush=True)
        break
EOF_FAKE
chmod +x "$FAKE"
T=$(CC_CODEX_USAGE_BIN="$FAKE" sh "$BIN/cc-codex-usage.sh" --tuple)
[ "$T" = "0.28 0.25 codex-app-server" ] || { echo "FAIL tuple: $T"; exit 1; }
J=$(CC_CODEX_USAGE_BIN="$FAKE" sh "$BIN/cc-codex-usage.sh" --json)
echo "$J" | grep -q '"used5hPercent":28' || { echo "FAIL json: $J"; exit 1; }
TASK="$TMP/task.md"; echo test > "$TASK"
H=$(CC_PG_CREDS="$TMP/none" CC_CODEX_USAGE_BIN="$FAKE" sh "$BIN/cc-estimate.sh" --task "$TASK" --model gpt-6-sol --backend codex --compact-html)
echo "$H" | grep -q '28%' || { echo "FAIL estimator 5h: $H"; exit 1; }
echo "$H" | grep -q '25%' || { echo "FAIL estimator 7d: $H"; exit 1; }
echo "$H" | grep -q 'codex-app-server' || { echo "FAIL source: $H"; exit 1; }
echo "OK: Codex usage 5h/7d comes from app-server and estimator labels source"
