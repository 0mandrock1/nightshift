#!/bin/sh
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
    def flush():
        if rows:
            result.append(table(["ліміт", "прогноз", "максимум"], rows))
            rows.clear()
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
    rm -f "$rich_body"
    return 0
  fi
  # Explicit rejection is safe to retry. Timeout or a 5xx may have delivered it.
  echo "rich: curl_rc=$rich_rc http=$rich_http" >&2
  rm -f "$rich_body"
  case "$rich_rc:$rich_http" in 0:400|0:403|0:404|0:405|0:501) return 1 ;; esac
  return 0
}
