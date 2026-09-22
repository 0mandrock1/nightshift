#!/bin/sh
# Доводить дві дельти, перенесені зі скіл-копії cc-remote-agent 1.2.0 у
# cc-run.sh: (a) автододавання секції "## Sync-only" у task.md, якщо автор
# забув; (b) мітка BG-WAIT у fail_reason/нотифікації, коли ран впав без
# рядка RESULT і в хвості логу є сліди фонового очікування.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0

# --- (a) sync-only autoappend, ран ok ---
D_OK="$TMP/runs/ok-run"
mkdir -p "$D_OK"
echo "Нічого не роби." > "$D_OK/task.md"

STUB_OK="$TMP/stub-claude-ok.sh"
cat > "$STUB_OK" <<'EOF'
#!/bin/sh
echo "RESULT: ok"
EOF
chmod +x "$STUB_OK"

CC_RUNS="$TMP/runs" CC_CLAUDE_BIN="$STUB_OK" CC_NOTIFY=/bin/true \
  sh "$BIN/cc-run.sh" "$D_OK" none haiku
RC=$?
[ "$RC" = 0 ] || { echo "FAIL(a): очікував exit 0, отримав $RC"; FAIL=1; }
grep -q '^## Sync-only' "$D_OK/task.md" || { echo "FAIL(a): секцію Sync-only не додано в task.md"; FAIL=1; }
grep -q '^## Sync-only' "$D_OK/task.md" && [ "$(grep -c '^## Sync-only' "$D_OK/task.md")" = "1" ] || { echo "FAIL(a): очікував рівно одну секцію Sync-only"; FAIL=1; }

# --- (a2) sync-only вже є — не дублювати ---
D_HAS="$TMP/runs/has-sync"
mkdir -p "$D_HAS"
printf 'Нічого не роби.\n\n## Sync-only\nвже тут\n' > "$D_HAS/task.md"
CC_RUNS="$TMP/runs" CC_CLAUDE_BIN="$STUB_OK" CC_NOTIFY=/bin/true \
  sh "$BIN/cc-run.sh" "$D_HAS" none haiku >/dev/null 2>&1
N=$(grep -c '^## Sync-only' "$D_HAS/task.md")
[ "$N" = "1" ] || { echo "FAIL(a2): очікував 1 наявну секцію Sync-only без дублювання, є $N"; FAIL=1; }

# --- (b) BG-WAIT мітка на провалі без RESULT ---
D_BG="$TMP/runs/bg-run"
mkdir -p "$D_BG"
echo "Нічого не роби." > "$D_BG/task.md"

STUB_BG="$TMP/stub-claude-bg.sh"
cat > "$STUB_BG" <<'EOF'
#!/bin/sh
echo "Чекаю на завершення фонової background задачі (monitor)."
exit 1
EOF
chmod +x "$STUB_BG"

CC_RUNS="$TMP/runs" CC_CLAUDE_BIN="$STUB_BG" CC_NOTIFY=/bin/true \
  sh "$BIN/cc-run.sh" "$D_BG" none haiku >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] || { echo "FAIL(b): очікував exit 2, отримав $RC"; FAIL=1; }
[ -f "$D_BG/fail_reason" ] || { echo "FAIL(b): нема $D_BG/fail_reason"; FAIL=1; }
if [ -f "$D_BG/fail_reason" ]; then
  R=$(cat "$D_BG/fail_reason")
  [ "$R" = "BG-WAIT" ] || { echo "FAIL(b): очікував BG-WAIT у fail_reason, є '$R'"; FAIL=1; }
fi

# --- (b2) провал без слідів фону -> NO-RESULT, не BG-WAIT ---
D_NR="$TMP/runs/nr-run"
mkdir -p "$D_NR"
echo "Нічого не роби." > "$D_NR/task.md"

STUB_NR="$TMP/stub-claude-nr.sh"
cat > "$STUB_NR" <<'EOF'
#!/bin/sh
echo "Просто впав без пояснень."
exit 1
EOF
chmod +x "$STUB_NR"

CC_RUNS="$TMP/runs" CC_CLAUDE_BIN="$STUB_NR" CC_NOTIFY=/bin/true \
  sh "$BIN/cc-run.sh" "$D_NR" none haiku >/dev/null 2>&1
if [ -f "$D_NR/fail_reason" ]; then
  R=$(cat "$D_NR/fail_reason")
  [ "$R" = "NO-RESULT" ] || { echo "FAIL(b2): очікував NO-RESULT у fail_reason, є '$R'"; FAIL=1; }
else
  echo "FAIL(b2): нема $D_NR/fail_reason"; FAIL=1
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: Sync-only автододається (без дублювання), BG-WAIT/NO-RESULT розрізняються у fail_reason"
