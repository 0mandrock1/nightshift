#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/estimate.json" <<'JSON'
{
  "eta": {"n": 10, "p50_seconds": 60, "p90_seconds": 180},
  "steps": [{"backend": "codex", "model": "demo<&", "effort": null,
    "eta_shadow": {"observed_seconds":[26,45],"n":3}}],
  "quotas": {"codex": {"source": "api", "windows": {
    "5h": {"used_percent": 50, "usable": true},
    "7d": {"used_percent": null, "usable": false}
  }}},
  "quota_forecast": {"backend": "codex", "windows": {
    "5h": {"typical_pp": 0.5, "planning_upper_pp": 2, "n": 10, "basis": "model"}
  }},
  "decision": {"action": "warn", "reason": "deadline_at_risk",
               "warnings": ["deadline_at_risk"]}
}
JSON
python3 "$BIN/cc-estimate-v3.py" render "$TMP/estimate.json" > "$TMP/card"
grep -Fx '<blockquote><b>ETA 1.0 хв · верх 3.0 хв</b>' "$TMP/card"
grep -Fx 'codex/demo&lt;&amp;' "$TMP/card"
grep -Fx 'Фактичні тривалості · 26–45 с · n=3 · рівень міркування' "$TMP/card"
grep -Fx '<b>Поточна квота</b>' "$TMP/card"
grep -F '5h &lt;1, верх 2 в.п.' "$TMP/card"
grep -Fx '⚠️ ризик вийти за дедлайн' "$TMP/card"
sh "$BIN/cc-tg-format.sh" preflight --id 'swarm<&' --tokens 100 --minutes 2 \
  --lanes 2 --tier 'demo<&' --pct5h 1 --pct7d 42 > "$TMP/legacy"
grep -F 'swarm&lt;&amp;' "$TMP/legacy"
grep -Fx '<blockquote><b>ETA ≈2 хв</b>' "$TMP/legacy"
grep -Fx -- '---WARN---' "$TMP/legacy"

mkdir "$TMP/bin"
printf 'SWARM_BOT_TOKEN=test\nSWARM_CHAT_ID=42\n' > "$TMP/environment"
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/sh
html=0
for arg do
  case "$arg" in
    parse_mode=HTML) html=1; printf '%s\n' "$arg" >> "$TEST_REQUESTS" ;;
    text=*) printf '%s\n' "${arg#text=}" >> "$TEST_REQUESTS" ;;
    disable_notification=*) printf '%s\n' "$arg" >> "$TEST_REQUESTS" ;;
  esac
done
if [ "$html" = 1 ] && [ "${TEST_REJECT_HTML:-0}" = 1 ]; then
  printf 400
else
  printf 200
fi
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" CC_NOTIFY_SWARM_ENV="$TMP/environment" TEST_REQUESTS="$TMP/requests"
TEST_REJECT_HTML=1 sh "$BIN/cc-notify-swarm.sh" "$(cat "$TMP/card")" silent
[ "$(grep -c '^parse_mode=HTML$' "$TEST_REQUESTS")" = 1 ]
[ "$(grep -c '^disable_notification=true$' "$TEST_REQUESTS")" = 2 ]
grep -Fx 'ETA 1.0 хв · верх 3.0 хв' "$TEST_REQUESTS"
grep -F '5h <1, верх 2 в.п.' "$TEST_REQUESTS"
: > "$TEST_REQUESTS"
sh "$BIN/cc-notify-swarm.sh" 'після рану'
[ "$(cat "$TEST_REQUESTS")" = 'після рану' ]
echo 'OK: Telegram estimate card, escapes, warning, and quiet swarm fallback'
