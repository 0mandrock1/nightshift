#!/bin/sh
# Поточне included-usage Codex через official local app-server RPC.
# Не читає/не друкує auth.json і не повертає accountId.
#   --tuple (default): <util5h_0..1> <util7d_0..1> codex-app-server
#   --json: redacted machine-readable snapshot
set -u
MODE=${1:---tuple}
CODEX_BIN=${CC_CODEX_USAGE_BIN:-codex}
command -v "$CODEX_BIN" >/dev/null 2>&1 || exit 1
CC_CODEX_USAGE_BIN="$CODEX_BIN" python3 - "$MODE" <<'PY'
import json, os, selectors, subprocess, sys, time
mode = sys.argv[1]
p = subprocess.Popen(
    [os.environ.get("CC_CODEX_USAGE_BIN", "codex"), "app-server", "--stdio"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    text=True, bufsize=1,
)
try:
    requests = [
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"nightshift-usage","version":"1"},"capabilities":{"experimentalApi":True}}},
        {"method":"initialized"},
        {"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":True,"supportsLunaReserve":True}},
    ]
    for request in requests:
        p.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    p.stdin.flush()
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + float(os.environ.get("CC_CODEX_USAGE_TIMEOUT", "6"))
    result = None
    while time.monotonic() < deadline:
        events = sel.select(max(0.0, deadline - time.monotonic()))
        if not events:
            break
        line = p.stdout.readline()
        if not line:
            break
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("id") == 2 and isinstance(obj.get("result"), dict):
            result = obj["result"]
            break
    if result is None:
        raise SystemExit(1)
    snap = (result.get("rateLimitsByLimitId") or {}).get("codex") or result.get("rateLimits") or {}
    primary, secondary = snap.get("primary") or {}, snap.get("secondary") or {}
    u5, u7 = primary.get("usedPercent"), secondary.get("usedPercent")
    if not isinstance(u5, (int, float)) or not isinstance(u7, (int, float)):
        raise SystemExit(1)
    redacted = {
        "util5h": round(float(u5) / 100, 4),
        "util7d": round(float(u7) / 100, 4),
        "used5hPercent": u5,
        "used7dPercent": u7,
        "reset5h": primary.get("resetsAt"),
        "reset7d": secondary.get("resetsAt"),
        "ordinaryUsageAllowed": result.get("ordinaryUsageAllowed"),
        "planType": snap.get("planType"),
        "source": "codex-app-server",
    }
    if mode == "--json":
        print(json.dumps(redacted, separators=(",", ":")))
    else:
        print(f'{redacted["util5h"]} {redacted["util7d"]} codex-app-server')
finally:
    try:
        p.terminate(); p.wait(timeout=1)
    except Exception:
        try: p.kill()
        except Exception: pass
PY
