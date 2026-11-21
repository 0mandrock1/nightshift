#!/bin/sh
# Реальна вартість одного рану: знаходить session-jsonl, що писався під час рану,
# і сумує токени по моделях. Пише <run-dir>/usage.json, друкує один рядок.
#   sh run-usage.sh <run-dir>
#
# ENV: CC_CLAUDE_PROJECTS (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/.claude/projects) — тека, де Claude Code
#      тримає session-jsonl транскрипти
set -u
D=${1:?run-dir}; D=${D%/}
CC_CLAUDE_PROJECTS=${CC_CLAUDE_PROJECTS:-$(getent passwd "$(id -un)" | cut -d: -f6)/.claude/projects}
[ -f "$D/task.md" ] || { echo "usage: нема task.md у $D"; exit 1; }
# A retry must not expose the previous attempt's usage after a failed lookup.
if [ -f "$D/usage.json" ]; then
  previous=$(mktemp "$D/.usage.previous.XXXXXX") || exit 3
  mv "$D/usage.json" "$previous" || exit 3
fi
if [ -f "$D/session_id" ]; then
  SID=$(cat "$D/session_id")
  case "$SID" in ''|*[!a-zA-Z0-9-]*) echo "usage: некоректний session_id"; exit 2 ;; esac
  SESS=$(find "$CC_CLAUDE_PROJECTS" -type f -name "$SID.jsonl" 2>/dev/null)
else
  # Read old runs without a session id only when the time window yields one candidate.
  START=$(stat -c %Y "$D/task.md")
  END=$([ -f "$D/out.log" ] && stat -c %Y "$D/out.log" || date +%s)
  SESS=$(find "$CC_CLAUDE_PROJECTS" -type f -name '*.jsonl' -newermt "@$((START - 30))" ! -newermt "@$((END + 90))" 2>/dev/null)
fi
case "$SESS" in
  '') echo "usage: сесію не знайдено для $(basename "$D")"; exit 2 ;;
  *'
'*) echo "usage: кілька можливих сесій для $(basename "$D")"; exit 2 ;;
esac
TMP=$(mktemp "$D/.usage.XXXXXX") || exit 3
trap 'rm -f "$TMP"' EXIT

jq -s --arg run "$(basename "$D")" --arg sess "$SESS" '
  [ .[] | select(.message.usage != null)
        | {model: (.message.model // "unknown"), u: .message.usage} ]
  | if length == 0 then halt_error(2) else . end
  | group_by(.model)
  | map({ model: .[0].model,
          input:  (map(.u.input_tokens // 0)               | add),
          output: (map(.u.output_tokens // 0)              | add),
          cache_w:(map(.u.cache_creation_input_tokens // 0)| add),
          cache_r:(map(.u.cache_read_input_tokens // 0)    | add) })
  | { run: $run, session: $sess, models: .,
      total_in:  (map(.input + .cache_w + .cache_r) | add),
      total_out: (map(.output) | add) }' "$SESS" > "$TMP" 2>/dev/null || { echo "usage: немає валідного обліку токенів"; exit 3; }
mv "$TMP" "$D/usage.json" || exit 3

jq -r '"USAGE \(.run): in=\(.total_in) out=\(.total_out) models=\([.models[].model]|join(","))"' "$D/usage.json"
