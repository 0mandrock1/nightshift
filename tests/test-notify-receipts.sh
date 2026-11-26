#!/bin/sh
# Telegram delivery receipts: message_id + delivery type per run, no token, mocked Bot API only.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TOKEN=FAKETOKEN-must-not-leak
mkdir "$TMP/bin"
printf 'BOT_TOKEN=%s\nOWNER_CHAT_ID=4242\n' "$TOKEN" > "$TMP/run.env"
printf 'SWARM_BOT_TOKEN=%s\nSWARM_CHAT_ID=4242\n' "$TOKEN" > "$TMP/swarm.env"
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/sh
kind=legacy; output=/dev/null
for a in "$@"; do case "$a" in */sendRichMessage) kind=rich ;; esac; done
while [ "$#" -gt 0 ]; do case "$1" in -o) output=$2; shift ;; esac; shift; done
printf '%s\n' "$kind" >> "$TEST_CALLS"
n=$(wc -l < "$TEST_CALLS")
case "$kind:$TEST_CASE" in
  rich:rich_ok) printf '{"ok":true,"result":{"message_id":%s,"rich_message":{"blocks":[]}}}' "$((100+n))" > "$output"; printf 200 ;;
  rich:rich_reject) printf '{"ok":false}' > "$output"; printf 400 ;;
  rich:rich_timeout) printf 000; exit 28 ;;
  rich:*) printf '{"ok":true,"result":{"message_id":%s}}' "$((100+n))" > "$output"; printf 200 ;;
  legacy:html_400) if [ "$n" -eq 1 ]; then printf '{"ok":false,"description":"bad"}' > "$output"; printf 400
                   else printf '{"ok":true,"result":{"message_id":%s}}' "$((200+n))" > "$output"; printf 200; fi ;;
  legacy:no_id) printf '{"ok":true}' > "$output"; printf 200 ;;
  legacy:*) printf '{"ok":true,"result":{"message_id":%s}}' "$((200+n))" > "$output"; printf 200 ;;
esac
CURL
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" CC_NOTIFY_ENV="$TMP/run.env" CC_NOTIFY_SWARM_ENV="$TMP/swarm.env"
export TEST_CALLS="$TMP/calls"
RICH='<b>ран · старт</b>
<blockquote expandable>
<b>⏱ ран · прогноз часу</b>
codex · gpt-6.2-sol · високий

<b>час поки невідомий</b>
орієнтовний час (проксі): <b><i>15 хв</i></b> · верх <b><i>19 хв</i></b>
ℹ попередня версія родини · gpt-6.1-sol ×7 · n=7 · не історія самої моделі

<b>🔋 ран · прогноз</b> лімітів
<b><i>5</i></b> год: проксі <b><i>11%</i></b> (70% → 59%) · орієнтир верху <b><i>14%</i></b>
ℹ історичний проксі gpt-6.1-sol, не гарантія; паралельні рани ділять одну квоту акаунта
</blockquote>'
check() {  # file, count, then "message_id:delivery:kind" lines expected on stdin
  python3 - "$1" "$2" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
expected = [tuple(x.split(":")) for x in sys.argv[2].split(",") if x]
got = [(str(r["message_id"]), r["delivery"], r["kind"]) for r in records]
assert got == expected, (got, expected)
assert all(r["schema"] == 1 and r["run"] == "run-1" and set(r) <= {"schema", "message_id", "delivery", "kind", "ts", "run"} for r in records)
PY
}
run() {  # notifier case message [silent]
  : > "$TEST_CALLS"
  TEST_CASE=$2 CC_NOTIFY_RECEIPTS="$R" CC_NOTIFY_RECEIPT_RUN=run-1 sh "$BIN/$1" "$3" ${4:-} 2>"$TMP/err" || return 1
  ! grep -q "$TOKEN\|4242" "$TMP/err"
}
for notifier in cc-notify.sh cc-notify-swarm.sh; do
  R="$TMP/$notifier.jsonl"; rm -f "$R"
  # Rich transport: id comes from sendRichMessage, delivered once (no fallback duplicate).
  run $notifier rich_ok "$RICH" silent
  [ "$(cat "$TEST_CALLS")" = rich ]
  check "$R" 101:rich:preflight
  # Rich rejected -> one ordinary send, one receipt for it only.
  run $notifier rich_reject "$RICH" silent
  [ "$(cat "$TEST_CALLS")" = "$(printf 'rich\nlegacy')" ]
  # Uncertain rich delivery (timeout) is not retried and produces no receipt.
  run $notifier rich_timeout "$RICH" silent
  [ "$(cat "$TEST_CALLS")" = rich ]
  # Ordinary preflight and afterflight.
  run $notifier ok 'звичайне' silent
  run $notifier ok '✅ готово'
  # HTML rejected -> plain fallback is the only receipt for that notification.
  run $notifier html_400 '<b>x</b>' silent
  # Response without a message_id writes nothing.
  run $notifier no_id '<b>y</b>' silent
  if [ "$notifier" = cc-notify.sh ]; then
    check "$R" 101:rich:preflight,202:html:preflight,201:html:preflight,201:html:notice,202:plain:preflight
  fi
done
# The ordinary path labels each transport; swarm afterflight is plain text.
R="$TMP/cc-notify.sh.jsonl"
[ "$(wc -l < "$R")" -eq 5 ]
grep -q '"delivery":"rich"' "$R" && grep -q '"delivery":"html"' "$R" && grep -q '"delivery":"plain"' "$R"
case "$(cat "$R")" in *"$TOKEN"*|*4242*) echo 'FAIL: receipt leaks token/chat'; exit 1 ;; esac
[ "$(stat -c %a "$R")" = 600 ]
grep -q '"delivery":"plain","kind":"notice"' "$TMP/cc-notify-swarm.sh.jsonl"
# Without a receipt file nothing is written and the notifier still succeeds.
: > "$TEST_CALLS"
TEST_CASE=rich_ok sh "$BIN/cc-notify.sh" "$RICH" silent 2>/dev/null
[ -z "$(find "$TMP" -newer "$TEST_CALLS" -name '*.jsonl' 2>/dev/null)" ]
# Unwritable receipt location never changes the result.
TEST_CASE=rich_ok CC_NOTIFY_RECEIPTS=/nonexistent/dir/r.jsonl sh "$BIN/cc-notify.sh" "$RICH" silent 2>/dev/null
# Rich table conversion of the fallback card.
: > "$TEST_CALLS"
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/sh
output=/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in
    rich_message=*) printf '%s' "${1#rich_message=}" > "$TEST_PAYLOAD" ;;
    -o) output=$2; shift ;;
  esac
  shift
done
printf '{"ok":true,"result":{"message_id":7}}' > "$output"
printf 200
CURL
TEST_PAYLOAD="$TMP/payload" sh "$BIN/cc-notify.sh" "$RICH" silent 2>/dev/null
python3 - "$TMP/payload" <<'PY'
import json, sys
html = json.load(open(sys.argv[1]))["html"]
assert '<th align="center">орієнтовний час (проксі)</th><th align="center">верх</th>' in html, html
assert "<b>час поки невідомий</b>" in html and "максимум" not in html
assert '<th align="center">ліміт</th><th align="center">проксі</th><th align="center">орієнтир верху</th>' in html, html
assert "<b><i>11%</i></b><br>(70% → 59%)</td>" in html and "<b><i>14%</i></b></td>" in html
assert "паралельні рани ділять одну квоту" in html and "<details>" in html
PY
echo 'OK: Telegram delivery receipts (rich, html, plain, swarm), per-run scope, no token, no duplicates'
