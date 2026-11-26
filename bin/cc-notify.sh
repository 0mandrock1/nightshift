#!/bin/sh
# Спільна точка нотифікації cc-ранів у Telegram.
# Шле напряму в Telegram API (НЕ через процес бота) — має працювати, навіть
# коли pm2-процес бота лежить.
#
#   sh cc-notify.sh "<текст>" [silent]
#
# Другий арг == "silent" -> disable_notification=true (пуш без звуку/вібрації).
# Використовується для preflight-повідомлень (старт), щоб не пінгати на кожен ран;
# afterflight (ok/fail/session limit/ланцюг) шлеться зі звуком (без цього арга).
#
# Формат: HTML parse_mode. Викликач може класти в текст <b>, <i>, <code>, <pre>.
# Правило оформлення (щоб повідомлення читалось із гудка телефону):
#   рядок 1 — статус жирним і що це за ран;
#   рядок 2 — run-id у <code> (моноширинний, зручно копіювати);
#   далі   — деталі, по рядку на факт.
# Якщо HTML не приймається (криві теги в тексті) — автоматичний ретрай ПЛЕЙНТЕКСТОМ,
# бо мовчазна нотифікація гірша за некрасиву.
#
# ENV: CC_NOTIFY_ENV  (дефолт <bin>/notify.env) — файл з BOT_TOKEN/OWNER_CHAT_ID
#      (див. notify.env.example; на живому вузлі — реальний .env, гітигнорований)
#
# Best-effort: ніколи не валить викликаючий скрипт, коди виходу не чіпає.
set -u

MSG=${1:-}
[ -n "$MSG" ] || exit 0
SILENT=${2:-}
# disable_notification шлеться обом curl-викликам завжди: true для silent (preflight),
# false інакше (afterflight зі звуком). Telegram приймає false як дефолт — дублювати
# curl-виклики не треба.
DN=false
[ "$SILENT" = "silent" ] && DN=true

BIN=$(dirname "$(readlink -f "$0")")
ENV_FILE=${CC_NOTIFY_ENV:-$BIN/notify.env}

BOT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
OWNER_CHAT_ID=$(grep -E '^OWNER_CHAT_ID=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

[ -n "${BOT_TOKEN:-}" ] || { echo "cc-notify: нема BOT_TOKEN" >&2; exit 0; }
[ -n "${OWNER_CHAT_ID:-}" ] || { echo "cc-notify: нема OWNER_CHAT_ID" >&2; exit 0; }

# Failed afterflight: readable notification + a single copyable plain-text block.
# Match the status prefix used by run/chain/seq, not words in agent NOTES.
# Risky-start warnings and quota deferrals are intentionally not failures.
ORIGINAL_MSG=$MSG
case "$MSG" in
  '❌ '*|'⏱️ '*|'☠️ '*|'⚠️ '*)
    if [ "$SILENT" != silent ]; then
      # Telegram limits the rendered text, not the escaped HTML source.
      # If duplication would exceed the limit, prefer the full copy block.
      # Keep the original notification if even the copy block is too large.
      if COPY_MSG=$(printf '%s' "$MSG" | python3 -c '
import html, re, sys
source = sys.stdin.read()
plain = html.unescape(re.sub(r"<[^>]*>", "", source))
block = "<pre>" + html.escape(plain, quote=False) + "</pre>"
units = len(plain.encode("utf-16-le")) // 2
if 2 * units + 2 <= 4096:
    print(source + "\n\n" + block)
elif units <= 4096:
    print(block)
else:
    print(source)
' 2>/dev/null); then
        MSG=$COPY_MSG
      else
        echo "cc-notify: copy block formatting failed; sending original" >&2
      fi
    fi
    ;;
esac

# Rich preflight is opt-in via the renderer's expandable quote marker.
[ -f "$BIN/cc-notify-rich.sh" ] && . "$BIN/cc-notify-rich.sh"
KIND=notice; [ "$SILENT" = silent ] && KIND=preflight
if [ "$SILENT" = silent ] && command -v cc_try_rich >/dev/null 2>&1; then
  if cc_try_rich "$MSG" "$BOT_TOKEN" "$OWNER_CHAT_ID" "$DN"; then exit 0; fi
fi

API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
# Тіло відповіді — лише для діагностики не-200 (поле description, токена в ньому
# нема); рішення "доставлено" все одно приймається за curl_rc + http.
BODY=$(mktemp 2>/dev/null) || BODY=/dev/null
trap '[ "$BODY" = /dev/null ] || rm -f "$BODY"' EXIT
api_err(){ [ "$BODY" = /dev/null ] || sed -n 's/.*"description":"\([^"]*\)".*/\1/p' "$BODY" 2>/dev/null | head -1 | cut -c1-200; }

# Беремо HTTP-код окремо від тіла: тіло може прийти порожнім/обрізаним (повільна
# мережа, підріз --max-time ПІСЛЯ того як Telegram уже прийняв повідомлення), і
# матч по тілу тоді хибно вважав це провалом → слав дубль. Тепер орієнтир — сам
# факт доставки: curl достукався (rc=0) і Telegram відповів 200.
HTTP=$(curl -sS --max-time 20 -o "$BODY" -w '%{http_code}' "$API" \
  --data-urlencode "chat_id=${OWNER_CHAT_ID}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "disable_notification=${DN}" \
  --data-urlencode "text=${MSG}" 2>/dev/null)
CURL_RC=$?
ERR=""; [ "$HTTP" = "200" ] || ERR=$(api_err)
echo "html: curl_rc=$CURL_RC http=$HTTP${ERR:+ api=$ERR}" >&2

# Ретрай ПЛЕЙНТЕКСТОМ лише коли повідомлення реально не пройшло: curl не достукався
# АБО код не 200 (напр. 400 через криві HTML-теги). rc=0 + 200 = доставлено, не дублюємо.
if [ "$CURL_RC" -eq 0 ] && [ "$HTTP" = "200" ]; then
  command -v cc_receipt >/dev/null 2>&1 && cc_receipt html "$BODY" "$KIND"
  [ "$KIND" != preflight ] || cc_refresh_receipt html "$BODY" "$MSG"
  exit 0
fi

# Фолбек: той самий текст без розмітки.
PLAIN=$(printf '%s' "$ORIGINAL_MSG" | sed -e 's/<[^>]*>//g')
HTTP2=$(curl -sS --max-time 20 -o "$BODY" -w '%{http_code}' "$API" \
  --data-urlencode "chat_id=${OWNER_CHAT_ID}" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "disable_notification=${DN}" \
  --data-urlencode "text=${PLAIN}" 2>/dev/null)
CURL_RC2=$?
ERR=""; [ "$HTTP2" = "200" ] || ERR=$(api_err)
echo "plain: curl_rc=$CURL_RC2 http=$HTTP2${ERR:+ api=$ERR}" >&2
if [ "$CURL_RC2" -eq 0 ] && [ "$HTTP2" = "200" ] && command -v cc_receipt >/dev/null 2>&1; then
  cc_receipt plain "$BODY" "$KIND"
  [ "$KIND" != preflight ] || cc_refresh_receipt plain "$BODY" "$PLAIN"
fi

exit 0
