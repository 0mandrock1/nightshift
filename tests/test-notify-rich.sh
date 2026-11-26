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
echo 'OK: Rich details closed by default; warning outside; explicit rejection fallback; no duplicate after ambiguous delivery'
