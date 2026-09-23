#!/bin/sh
# Гард повторного запуску в ту саму run-dir: другий паралельний виклик на
# ту саму теку падає exit 7 без нотифікації; stale-лок з мертвим pid не
# блокує; після нормального завершення .running прибрано.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CC_RUNS="$TMP/runs"
mkdir -p "$CC_RUNS"

NOTIFY_LOG="$TMP/notify-calls.log"
NOTIFY_STUB="$TMP/notify.sh"
cat > "$NOTIFY_STUB" <<EOF
#!/bin/sh
echo "call" >> "$NOTIFY_LOG"
exit 0
EOF
chmod +x "$NOTIFY_STUB"

CLAUDE_STUB="$TMP/claude.sh"
cat > "$CLAUDE_STUB" <<'EOF'
#!/bin/sh
echo "RESULT: ok"
EOF
chmod +x "$CLAUDE_STUB"

FAIL=0

# --- (a) другий паралельний виклик на ту саму run-dir -> exit 7 ---
D_A="$CC_RUNS/dup-a"
mkdir -p "$D_A"
echo "task" > "$D_A/task.md"
mkdir "$D_A/.running"
echo 999999 > "$D_A/.running/pid"
# 999999 майже напевно не живий pid, тому підмінимо на живий (свій $$) щоб
# симулювати "ран іде" детерміновано.
echo $$ > "$D_A/.running/pid"

: > "$NOTIFY_LOG"
CC_RUNS="$CC_RUNS" CC_NOTIFY="$NOTIFY_STUB" CC_CLAUDE_BIN="$CLAUDE_STUB" \
  sh "$BIN/cc-run.sh" "$D_A" none "" claude
RC=$?
if [ "$RC" != "7" ]; then echo "FAIL(a): очікував exit 7, отримав $RC"; FAIL=1; fi
N=$(wc -l < "$NOTIFY_LOG" 2>/dev/null || echo 0)
if [ "$N" != "0" ]; then echo "FAIL(a): notify викликано $N разів, очікував 0"; FAIL=1; fi
rm -rf "$D_A/.running"

# --- (b) stale-лок з мертвим pid -> ран проходить ---
D_B="$CC_RUNS/dup-b"
mkdir -p "$D_B"
echo "task" > "$D_B/task.md"
mkdir "$D_B/.running"
DEADPID=$(( $$ + 90000 ))
echo "$DEADPID" > "$D_B/.running/pid"
if kill -0 "$DEADPID" 2>/dev/null; then
  echo "FAIL(b): обраний pid $DEADPID виявився живим, тест ненадійний"; FAIL=1
fi

: > "$NOTIFY_LOG"
CC_RUNS="$CC_RUNS" CC_NOTIFY="$NOTIFY_STUB" CC_CLAUDE_BIN="$CLAUDE_STUB" \
  sh "$BIN/cc-run.sh" "$D_B" none "" claude
RC=$?
if [ "$RC" != "0" ]; then echo "FAIL(b): stale-лок мав пропустити ран (exit 0), отримав $RC"; cat "$D_B/out.log" 2>&1; FAIL=1; fi

# --- (c) після нормального завершення .running прибрано ---
if [ -d "$D_B/.running" ]; then echo "FAIL(c): .running лишився після завершення рану"; FAIL=1; fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: дублікатний запуск -> exit 7 без нотифікації, stale-лок пропускає ран, .running прибирається"
