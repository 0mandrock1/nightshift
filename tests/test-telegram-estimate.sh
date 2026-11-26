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
grep -Fx 'орієнтовний час: <b><i><u>1 хв</u></i></b> · максимум <b><i><u>3 хв</u></i></b>' "$TMP/card"
grep -Fx 'codex · demo&lt;&amp;' "$TMP/card"
grep -Fx '<b>🔋 ран · прогноз</b> лімітів' "$TMP/card"
grep -Fx '<b><i><u>5</u></i></b> год: <b><i><u>0.5%</u></i></b> (50% → 49.5%) · максимум <b><i><u>2%</u></i></b> (50% → 48%)' "$TMP/card"
grep -Fx '<b><i><u>7</u></i></b> днів: <b>немає даних</b> · прогноз н/д' "$TMP/card"
grep -Fx '• ризик вийти за дедлайн' "$TMP/card"
jq '.eta={n:2,p50_seconds:null,p90_seconds:null} |
    .quotas.codex.windows["5h"]={used_percent:94,usable:false} |
    .quota_forecast.windows={"5h":{n:1,basis:"model"},"7d":{n:0,basis:"model"}} |
    .decision={action:"defer",reason:"codex_provider_denied",retry_at:1795725728}'     "$TMP/estimate.json" > "$TMP/sparse.json"
python3 "$BIN/cc-estimate-v3.py" render "$TMP/sparse.json" > "$TMP/sparse"
grep -Fx '<b>час поки невідомий</b>' "$TMP/sparse"
grep -Fx '<b><i><u>5</u></i></b> год: <b>неактуально</b> · прогноз н/д' "$TMP/sparse"
! grep -q '→' "$TMP/sparse"
grep -Fx '<b>⚠ запуск відкладено</b>' "$TMP/sparse"
grep -Fx '• повтор після 26.11 22:42 за Києвом' "$TMP/sparse"
! grep -q 'максимум' "$TMP/sparse"
# Zero is an unobserved change, not free usage. Stale readings cannot yield
# a projected balance; exhausted windows must warn instead of going negative.
jq '.quota_forecast.windows["7d"]={typical_pp:0,planning_upper_pp:2,n:9,basis:"model_effort"} |
    .quotas.codex.windows["7d"]={used_percent:28,usable:true} |
    .quotas.codex.windows["5h"]={used_percent:99,usable:true}' "$TMP/estimate.json" > "$TMP/zero.json"
python3 "$BIN/cc-estimate-v3.py" render "$TMP/zero.json" > "$TMP/zero"
grep -Fx '<b><i><u>7</u></i></b> днів: <b><i><u>0%</u></i></b> (72% → 72%) · максимум <b><i><u>2%</u></i></b> (72% → 70%)' "$TMP/zero"
grep -Fx '<b><i><u>5</u></i></b> год: <b><i><u>0.5%</u></i></b> (1% → 0.5%) · максимум <b><i><u>2%</u></i></b> (1% → 0%) ⚠ може не вистачити' "$TMP/zero"
! grep -q 'Максимум — прогноз' "$TMP/zero"
! grep -q '≈' "$TMP/zero"
! grep -q 'в.п.' "$TMP/zero"
jq '.quotas.codex.windows["5h"].usable=false' "$TMP/estimate.json" > "$TMP/stale.json"
python3 "$BIN/cc-estimate-v3.py" render "$TMP/stale.json" > "$TMP/stale"
! grep -q '→' "$TMP/stale"
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
grep -Fx 'орієнтовний час: 1 хв · максимум 3 хв' "$TEST_REQUESTS"
grep -Fx '5 год: 0.5% (50% → 49.5%) · максимум 2% (50% → 48%)' "$TEST_REQUESTS"
: > "$TEST_REQUESTS"
sh "$BIN/cc-notify-swarm.sh" 'після рану'
[ "$(cat "$TEST_REQUESTS")" = 'після рану' ]
echo 'OK: Telegram estimate card, escapes, warning, and quiet swarm fallback'
