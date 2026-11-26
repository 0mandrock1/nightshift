#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
printf 'BOT_TOKEN=fake\nOWNER_CHAT_ID=42\n' > "$TMP/run.env"
printf 'SWARM_BOT_TOKEN=fake\nSWARM_CHAT_ID=42\n' > "$TMP/swarm.env"
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/sh
kind=plain
output=/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in
    */sendRichMessage) kind=rich ;;
    */sendMessage) kind=legacy ;;
    rich_message=*) printf '%s' "${1#rich_message=}" > "$TEST_PAYLOAD" ;;
    -o) output=$2; shift ;;
    text=*) printf '%s' "${1#text=}" > "$TEST_LEGACY" ;;
  esac
  shift
done
printf '%s\n' "$kind" >> "$TEST_CALLS"
if [ "$kind" = rich ]; then
  case "$TEST_CASE" in
    success) printf '{"ok":true,"result":{"rich_message":{"blocks":[{"type":"paragraph"},{"type":"details"},{"type":"paragraph"}]}}}' > "$output"; printf 200 ;;
    reject) printf '{"ok":false,"error_code":400}' > "$output"; printf 400 ;;
    timeout) printf 000; exit 28 ;;
    server) printf 500 ;;
  esac
else
  printf '{"ok":true}' > "$output"; printf 200
fi
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" CC_NOTIFY_ENV="$TMP/run.env" CC_NOTIFY_SWARM_ENV="$TMP/swarm.env"
export TEST_CALLS="$TMP/calls" TEST_PAYLOAD="$TMP/payload" TEST_LEGACY="$TMP/legacy"
MSG='<b>ран · старт</b>
<code>id&lt;&amp;</code>
<blockquote expandable>
<b><i>7 хв</i></b>
</blockquote>
⚠ увага'
for notifier in cc-notify.sh cc-notify-swarm.sh; do
  : > "$TEST_CALLS"
  TEST_CASE=success sh "$BIN/$notifier" "$MSG" silent 2>"$TMP/log"
  [ "$(cat "$TEST_CALLS")" = rich ]
  grep -F 'ok=True blocks=paragraph,details,paragraph' "$TMP/log"
  python3 - "$TEST_PAYLOAD" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
assert payload["skip_entity_detection"] is True
h = payload["html"]
assert h == '<p><b>ран · старт</b></p><p><code>id&lt;&amp;</code></p><details><summary>📊 прогноз часу та лімітів</summary><p><b><i>7 хв</i></b></p></details><p>⚠ увага</p>', h
PY
  : > "$TEST_CALLS"
  TEST_CASE=reject sh "$BIN/$notifier" "$MSG" silent
  [ "$(cat "$TEST_CALLS")" = "$(printf 'rich\nlegacy')" ]
  grep -F '<blockquote expandable>' "$TEST_LEGACY"
  for scenario in timeout server; do
    : > "$TEST_CALLS"
    TEST_CASE=$scenario sh "$BIN/$notifier" "$MSG" silent
    [ "$(cat "$TEST_CALLS")" = rich ]
  done
  : > "$TEST_CALLS"
  TEST_CASE=success CC_NOTIFY_RICH=0 sh "$BIN/$notifier" "$MSG" silent
  [ "$(cat "$TEST_CALLS")" = legacy ]
  : > "$TEST_CALLS"
  TEST_CASE=success sh "$BIN/$notifier" 'звичайне повідомлення' silent
  [ "$(cat "$TEST_CALLS")" = legacy ]
done
# Real preflight shape: native tables, equal columns, balance on a separate line,
# sparse/stale forecasts, and a quota warning must all survive conversion.
CARD='<blockquote expandable>
<b>⏱ ран · прогноз часу</b>
codex · gpt-6-luna · високий

орієнтовний час: <b><i>7 хв</i></b> · максимум <b><i>24 хв</i></b>

<b>🔋 ран · прогноз</b> лімітів
<b><i>5</i></b> год: <b><i>1%</i></b> (65% → 64%) · максимум <b><i>4%</i></b> (65% → 61%)
<b><i>7</i></b> днів: <b><i>0%</i></b> (72% → 72%) · максимум <b><i>2%</i></b> (72% → 70%)
</blockquote>
⚠ увага'
TEST_CASE=success sh "$BIN/cc-notify.sh" "$CARD" silent
python3 - "$TEST_PAYLOAD" <<'PYTEST'
import json, sys
h = json.load(open(sys.argv[1]))["html"]
assert h.count("<table compact>") == 2
assert h.count("<tr>") == 5
assert h.count("<th align=") == 5
for v in ("<b><i>7 хв</i></b>", "<b><i>24 хв</i></b>",
          "<b><i>1%</i></b><br>(65% → 64%)", "<b><i>4%</i></b><br>(65% → 61%)",
          "<b><i>0%</i></b><br>(72% → 72%)", "<b><i>2%</i></b><br>(72% → 70%)"):
    assert v in h, v
assert h.endswith("</details><p>⚠ увага</p>")
PYTEST
SPARSE='<blockquote expandable>
<b>🔋 ран · прогноз</b> лімітів
<b><i>5</i></b> год: <b><i>0.5%</i></b> (1% → 0.5%) · максимум <b><i>2%</i></b> (1% → 0%) ⚠ може не вистачити
<b><i>7</i></b> днів: <b>неактуально</b> · прогноз н/д
<b>◈ claude · вільний ліміт</b>
<b><i>5</i></b> год: <b><i>80%</i></b>
</blockquote>'
TEST_CASE=success sh "$BIN/cc-notify.sh" "$SPARSE" silent
python3 - "$TEST_PAYLOAD" <<'PYTEST'
import json, sys
h = json.load(open(sys.argv[1]))["html"]
assert h.count("<table compact>") == 1
assert "colspan=\"2\"><b>неактуально</b> · прогноз н/д" in h
assert "</table><p>⚠ <b><i>5</i></b> год: може не вистачити</p>" in h
assert "<p><b><i>5</i></b> год: <b><i>80%</i></b></p>" in h
PYTEST
echo 'OK: Rich details closed by default; warning outside; explicit rejection fallback; no duplicate after ambiguous delivery'
