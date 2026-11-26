#!/bin/sh
# Delivery receipt for one successful Telegram send, scoped to one run.
#   cc_receipt <delivery: rich|html|plain> <response-body-file> <kind: preflight|notice>
# Appends {message_id, delivery, kind, ts[, run]} to $CC_NOTIFY_RECEIPTS (a per-run file set by the
# caller; unset = no receipt). Only the message_id is read from the response: no token, chat id or
# text is stored. Best-effort: never changes the notifier's result.
cc_receipt() {
  [ -n "${CC_NOTIFY_RECEIPTS:-}" ] && [ -f "$2" ] || return 0
  python3 -c '
import json, os, sys, time
try:
    message_id = json.load(open(sys.argv[2]))["result"]["message_id"]
    if type(message_id) is not int or message_id <= 0:
        sys.exit(0)
    record = {"schema": 1, "message_id": message_id, "delivery": sys.argv[1], "kind": sys.argv[3],
              "ts": round(time.time(), 3)}
    if os.environ.get("CC_NOTIFY_RECEIPT_RUN"):
        record["run"] = os.environ["CC_NOTIFY_RECEIPT_RUN"]
    fd = os.open(os.environ["CC_NOTIFY_RECEIPTS"], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as out:
        out.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
except (OSError, ValueError, KeyError, TypeError):
    pass
' "$1" "$2" "${3:-notice}" 2>/dev/null || true
  return 0
}

# Schedule only for an explicit v3 preflight and the exact successful response.
# Content arrives via stdin; credentials stay in the existing private env file.
cc_refresh_receipt() {
  [ "${CC_NOTIFY_REFRESH:-1}" != 0 ] && [ -f "${CC_NOTIFY_PREFLIGHT_JSON:-}" ] || return 0
  printf '%s' "$3" | python3 "$BIN/cc-notify-refresh.py" schedule "$CC_NOTIFY_PREFLIGHT_JSON" "$2" "$1" "$ENV_FILE" "${CC_NOTIFY_VARIANT:-run}" || true
}

# Shared opt-in Rich Messages transport for a preflight's expandable quote.
# Return 0: delivered or delivery uncertain (do not duplicate);
# return 1: not applicable or explicitly rejected (use ordinary Telegram HTML).
cc_try_rich() {
  case "$1" in *'<blockquote expandable>'*) ;; *) return 1 ;; esac
  [ "${CC_NOTIFY_RICH:-1}" != 0 ] || return 1
  rich_payload=$(printf '%s' "$1" | python3 -c '
import json, sys
source = sys.stdin.read()
opening = "<blockquote expandable>"
closing = "</blockquote>"
if source.count(opening) != 1 or source.count(closing) != 1:
    sys.exit(1)
prefix, body = source.split(opening, 1)
body, suffix = body.split(closing, 1)
def paragraphs(text):
    return "".join("<p>" + line + "</p>" for line in text.splitlines() if line.strip())
def table(headers, rows):
    head = "<tr>" + "".join("<th align=\"center\">" + h + "</th>" for h in headers) + "</tr>"
    return "<table compact>" + head + "".join(rows) + "</table>"

def cell(value, align="center", span=1):
    return f"<td align=\"{align}\" valign=\"middle\" colspan=\"{span}\">{value}</td>"

def quota_value(value):
    # Keep the estimated spend bold/italic, but move its balance onto its own line.
    return value.replace(" (", "<br>(", 1)

def format_card(text):
    result, rows, warnings = [], [], []
    in_quota = False
    proxy = []
    def flush():
        if rows:
            headers = ["ліміт", "проксі", "орієнтир верху"] if proxy else ["ліміт", "прогноз", "максимум"]
            result.append(table(headers, rows))
            rows.clear()
            proxy.clear()
        result.extend(paragraphs(w) for w in warnings)
        warnings.clear()
    for line in text.splitlines():
        if not line.strip():
            flush()
            continue
        if line.startswith("<b>🔋 "):
            flush()
            in_quota = True
        elif line.startswith("<b>◈ "):
            flush()
            in_quota = False
        if line.startswith(("орієнтовний час:", "орієнтовний час плану:")) and " · максимум " in line:
            flush()
            label, value = line.split(": ", 1)
            typical, upper = value.split(" · максимум ", 1)
            result.append(table([label, "максимум"], ["<tr>" + cell(typical) + cell(upper) + "</tr>"]))
            continue
        if line.startswith(("орієнтовний час (проксі):", "орієнтовний час плану (проксі):")) and " · верх " in line:
            flush()
            label, value = line.split(": ", 1)
            typical, upper = value.split(" · верх ", 1)
            result.append(table([label, "верх"], ["<tr>" + cell(typical) + cell(upper) + "</tr>"]))
            continue
        if in_quota and line.startswith(("<b><i>5</i></b> год: ", "<b><i>7</i></b> днів: ")):
            label, value = line.split(": ", 1)
            if " · максимум " in value:
                typical, upper = value.split(" · максимум ", 1)
                if " ⚠ " in upper:
                    upper, warning = upper.split(" ⚠ ", 1)
                    warnings.append("⚠ " + label + ": " + warning)
                if " · залишок: " in upper:
                    upper, balance = upper.split(" · залишок: ", 1)
                    warnings.append(label + " · залишок: " + balance)
                rows.append("<tr>" + cell(label, "left") + cell(quota_value(typical))
                            + cell(quota_value(upper)) + "</tr>")
            elif " · орієнтир верху " in value:
                typical, upper = value.split(" · орієнтир верху ", 1)
                proxy.append(True)
                rows.append("<tr>" + cell(label, "left") + cell(quota_value(typical.removeprefix("проксі ")))
                            + cell(upper) + "</tr>")
            else:
                rows.append("<tr>" + cell(label, "left") + cell(value, span=2) + "</tr>")
            continue
        flush()
        result.append(paragraphs(line))
    flush()
    return "".join(result)

html = (paragraphs(prefix) + "<details><summary>📊 прогноз часу та лімітів</summary>"
        + format_card(body) + "</details>" + paragraphs(suffix))
print(json.dumps({"html": html, "skip_entity_detection": True}, ensure_ascii=False))
' 2>/dev/null) || return 1
  rich_body=$(mktemp 2>/dev/null) || return 1
  rich_http=$(curl -sS --max-time 15 -o "$rich_body" -w '%{http_code}' \
    "https://api.telegram.org/bot${2}/sendRichMessage" \
    --data-urlencode "chat_id=$3" --data-urlencode "disable_notification=$4" \
    --data-urlencode "rich_message=$rich_payload" 2>/dev/null)
  rich_rc=$?
  if [ "$rich_rc" -eq 0 ] && [ "$rich_http" = 200 ]; then
    # Only log structural metadata, not the chat id or message text.
    rich_meta=$(python3 -c '
import json, sys
try:
    response = json.load(open(sys.argv[1]))
    result = response.get("result", {})
    blocks = result.get("rich_message", {}).get("blocks", [])
    types = [b.get("type", "?") for b in blocks]
    print("ok=%s blocks=%s" % (response.get("ok") is True, ",".join(types)))
    for block in blocks:
        if block.get("type") == "details":
            nested = block.get("blocks", [])
            tables = [b for b in nested if b.get("type") == "table"]
            print("details_open=%s tables=%s rows=%s compact=%s" % (
                bool(block.get("is_open")), len(tables),
                ",".join(str(len(t.get("cells", []))) for t in tables),
                all(t.get("is_compact") for t in tables)))
except (OSError, ValueError, AttributeError, TypeError):
    print("response_unverified")
' "$rich_body" 2>/dev/null)
    echo "rich: curl_rc=$rich_rc http=$rich_http $rich_meta" >&2
    cc_receipt rich "$rich_body" preflight
    cc_refresh_receipt rich "$rich_body" "$rich_payload"
    rm -f "$rich_body"
    return 0
  fi
  # Explicit rejection is safe to retry. Timeout or a 5xx may have delivered it.
  echo "rich: curl_rc=$rich_rc http=$rich_http" >&2
  rm -f "$rich_body"
  case "$rich_rc:$rich_http" in 0:400|0:403|0:404|0:405|0:501) return 1 ;; esac
  return 0
}
