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
grep -Fx 'Типово: <b>≈ 1 хв</b>' "$TMP/card"
grep -Fx 'Codex · demo&lt;&amp;' "$TMP/card"
grep -Fx '<i>Заміри: 26–45 с · 3 ранів</i>' "$TMP/card"
grep -Fx '<b>◈ Ліміти Codex на старті</b>' "$TMP/card"
grep -F '5 год: <b>≈0.5 в.п.</b> · із запасом 2' "$TMP/card"
grep -Fx '• ризик вийти за дедлайн' "$TMP/card"
grep -Fx 'Із запасом: <b>≈ 3 хв</b>' "$TMP/card"
grep -Fx '5 год: ▰▰▰▰▰▱▱▱▱▱ <b>50% вільно</b>' "$TMP/card"
grep -Fx '7 днів: немає даних' "$TMP/card"
jq '.eta={n:2,p50_seconds:null,p90_seconds:null} |
    .quotas.codex.windows["5h"]={used_percent:94,usable:false} |
    .quota_forecast.windows={"5h":{n:1,basis:"model"},"7d":{n:0,basis:"model"}} |
    .decision={action:"defer",reason:"codex_provider_denied",retry_at:1795725728}'     "$TMP/estimate.json" > "$TMP/sparse.json"
python3 "$BIN/cc-estimate-v3.py" render "$TMP/sparse.json" > "$TMP/sparse"
grep -Fx '<b>Час поки невідомий</b>' "$TMP/sparse"
grep -Fx '5 год: 94% використано · неактуально' "$TMP/sparse"
grep -Fx '5 год: мало даних · 1/5 замірів' "$TMP/sparse"
grep -Fx '<b>⚠ Запуск відкладено</b>' "$TMP/sparse"
grep -Fx '• Повтор після 26.11 22:42 за Києвом' "$TMP/sparse"
! grep -q 'вільно' "$TMP/sparse"
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
grep -Fx 'Типово: ≈ 1 хв' "$TEST_REQUESTS"
grep -F '5 год: ≈0.5 в.п. · із запасом 2' "$TEST_REQUESTS"
: > "$TEST_REQUESTS"
sh "$BIN/cc-notify-swarm.sh" 'після рану'
[ "$(cat "$TEST_REQUESTS")" = 'після рану' ]
echo 'OK: Telegram estimate card, escapes, warning, and quiet swarm fallback'
