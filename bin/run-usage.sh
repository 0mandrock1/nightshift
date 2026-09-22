#!/bin/sh
# Реальна вартість одного рану: знаходить session-jsonl, що писався під час рану,
# і сумує токени по моделях. Пише <run-dir>/usage.json, друкує один рядок.
#   sh run-usage.sh <run-dir>
#
# ENV: CC_CLAUDE_PROJECTS (дефолт $HOME/.claude/projects) — тека, де Claude Code
#      тримає session-jsonl транскрипти
set -u
D=${1:?run-dir}; D=${D%/}
CC_CLAUDE_PROJECTS=${CC_CLAUDE_PROJECTS:-$HOME/.claude/projects}
[ -f "$D/task.md" ] || { echo "usage: нема task.md у $D"; exit 1; }
START=$(stat -c %Y "$D/task.md")
END=$([ -f "$D/out.log" ] && stat -c %Y "$D/out.log" || date +%s)
END=$((END + 90))

SESS=""
if [ -f "$D/session_id" ]; then
  SID=$(cat "$D/session_id")
  SESS=$(find "$CC_CLAUDE_PROJECTS" -name "$SID.jsonl" 2>/dev/null | head -1)
fi
if [ -z "$SESS" ]; then
  # Фолбек для ранів без session_id (до 30.08) — стара time-window евристика,
  # не гарантія: може приліпити чужу сесію (відомий трап).
  SESS=$(find "$CC_CLAUDE_PROJECTS" -name '*.jsonl' -newermt "@$((START - 30))" ! -newermt "@$END" \
         -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
fi
[ -n "$SESS" ] || { echo "usage: сесію не знайдено для $(basename "$D")"; exit 2; }

jq -s --arg run "$(basename "$D")" --arg sess "$SESS" '
  [ .[] | select(.message.usage != null)
        | {model: (.message.model // "unknown"), u: .message.usage} ]
  | group_by(.model)
  | map({ model: .[0].model,
          input:  (map(.u.input_tokens // 0)               | add),
          output: (map(.u.output_tokens // 0)              | add),
          cache_w:(map(.u.cache_creation_input_tokens // 0)| add),
          cache_r:(map(.u.cache_read_input_tokens // 0)    | add) })
  | { run: $run, session: $sess, models: .,
      total_in:  (map(.input + .cache_w + .cache_r) | add),
      total_out: (map(.output) | add) }' "$SESS" > "$D/usage.json" || exit 3

jq -r '"USAGE \(.run): in=\(.total_in) out=\(.total_out) models=\([.models[].model]|join(","))"' "$D/usage.json"
