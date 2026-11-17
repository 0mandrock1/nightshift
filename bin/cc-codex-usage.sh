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
    bufsize=0,
)
try:
    requests = [
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"nightshift-usage","version":"1"},"capabilities":{"experimentalApi":True}}},
        {"method":"initialized"},
        {"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":True,"supportsLunaReserve":True}},
    ]
    p.stdin.write("".join(json.dumps(request, separators=(",", ":")) + "\n" for request in requests).encode())
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + float(os.environ.get("CC_CODEX_USAGE_TIMEOUT", "6"))
    result = None
    buffer = b""
    while time.monotonic() < deadline and result is None:
        if not sel.select(max(0.0, deadline - time.monotonic())):
            break
        chunk = os.read(p.stdout.fileno(), 65536)
        if not chunk:
            break
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and obj.get("id") == 2 and isinstance(obj.get("result"), dict):
                result = obj["result"]
                break
        if len(buffer) > 1024 * 1024:
            break
    if result is None:
        raise SystemExit(1)
    snap = (result.get("rateLimitsByLimitId") or {}).get("codex") or result.get("rateLimits") or {}
    primary, secondary = snap.get("primary") or {}, snap.get("secondary") or {}
    u5, u7 = primary.get("usedPercent"), secondary.get("usedPercent")
    def valid(value):
        return value if type(value) in (int, float) and 0 <= value <= 1000 else None

    u5, u7 = valid(u5), valid(u7)
    if u5 is None and u7 is None and type(result.get("ordinaryUsageAllowed")) is not bool:
        raise SystemExit(1)
    redacted = {
        "util5h": round(u5 / 100, 4) if u5 is not None else None,
        "util7d": round(u7 / 100, 4) if u7 is not None else None,
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
        a, b = ("" if redacted[key] is None else str(redacted[key]) for key in ("util5h", "util7d"))
        print(f"{a} {b} codex-app-server")
finally:
    try:
        p.terminate(); p.wait(timeout=1)
    except Exception:
        try: p.kill()
        except Exception: pass
PY
