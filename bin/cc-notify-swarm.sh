#!/bin/sh
# Нотифікація РОЮ у виділений бот (окремий від cc-notify.sh).
# Окремий канал навмисно: рій шумить пачками, cc-рани — поштучно.
#   sh cc-notify-swarm.sh "<текст>" [silent]
# silent — HTML preflight без звуку, включно зі стартом лейнів через cc-run.sh.
# Best-effort: ніколи не валить викликаючий скрипт.
#
# ENV: CC_NOTIFY_SWARM_ENV (дефолт <bin>/notify-swarm.env) — файл з
#      SWARM_BOT_TOKEN/SWARM_CHAT_ID. SWARM_ENV лишено як алiас для
#      зворотної сумісності (старіша назва змінної).
set -u
MSG=${1:-}
[ -n "$MSG" ] || exit 0
BIN=$(dirname "$(readlink -f "$0")")
ENV_FILE=${CC_NOTIFY_SWARM_ENV:-${SWARM_ENV:-$BIN/notify-swarm.env}}
T=$(grep -E '^SWARM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
C=$(grep -E '^SWARM_CHAT_ID=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
[ -n "${T:-}" ] && [ -n "${C:-}" ] || exit 0
[ -f "$BIN/cc-notify-rich.sh" ] && . "$BIN/cc-notify-rich.sh"
CC_NOTIFY_VARIANT=swarm
BODY=$(mktemp 2>/dev/null) || BODY=/dev/null
trap '[ "$BODY" = /dev/null ] || rm -f "$BODY"' EXIT
send(){
  curl -sS --max-time 10 "https://api.telegram.org/bot${T}/sendMessage" \
    --data-urlencode "chat_id=${C}" --data-urlencode "text=${MSG}" "$@" \
    -o "$BODY" -w '%{http_code}' 2>/dev/null
}
receipt(){ [ "$1" = 200 ] && command -v cc_receipt >/dev/null 2>&1 && cc_receipt "$2" "$BODY" "$3"; return 0; }
if [ "${2:-}" = silent ]; then
  if command -v cc_try_rich >/dev/null 2>&1; then
    if cc_try_rich "$MSG" "$T" "$C" true; then exit 0; fi
  fi
  HTTP=$(send --data-urlencode 'parse_mode=HTML' --data-urlencode 'disable_notification=true')
  receipt "$HTTP" html preflight
  [ "$HTTP" != 200 ] || cc_refresh_receipt html "$BODY" "$MSG"
  # Retry explicitly rejected markup as text. A transport failure may already have delivered it.
  if [ "$HTTP" = 400 ]; then
    MSG=$(printf '%s' "$MSG" | sed -e 's/<[^>]*>//g' -e 's/\&lt;/</g' -e 's/\&gt;/>/g' -e 's/\&amp;/\&/g')
    HTTP=$(send --data-urlencode 'disable_notification=true')
    receipt "$HTTP" plain preflight
    [ "$HTTP" != 200 ] || cc_refresh_receipt plain "$BODY" "$MSG"
  fi
else
  HTTP=$(send)
  receipt "$HTTP" plain notice
fi
exit 0
