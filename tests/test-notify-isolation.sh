#!/bin/sh
# Доводить, що cc-chain.sh поважає CC_NOTIFY (регрес: notify()/notify_silent()
# раніше хардкодили "$BIN/cc-notify.sh" в обхід CC_NOTIFY, тож тести з
# CC_NOTIFY=/bin/true все одно ганяли реальний Telegram-нотифаєр).
#   1. CC_NOTIFY -> лічильник-скрипт; ганяємо ланцюг зі сценарієм quota
#      (той самий фейковий CC_CODEX_BIN, що й tests/test-chain-codex.sh) —
#      лічильник має стати >0 (notify_silent на старті + notify на session limit).
#   2. Той самий прогін під strace -f -e trace=execve: у трейсі не повинно
#      бути жодного execve справжнього bin/cc-notify.sh (доказ, що реальний
#      нотифаєр НІКОЛИ не запускався, а не просто "мовчав").
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
REAL_NOTIFY="$BIN/cc-notify.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0

# --- фейковий codex CLI (сценарій quota, як у test-chain-codex.sh) ---
STUB="$TMP/fake-codex"
cat > "$STUB" <<'EOF'
#!/bin/sh
set -u
while [ $# -gt 0 ]; do
  case "$1" in
    exec) shift ;;
    -m|-o|-s|-C|--add-dir|-c) shift 2 ;;
    --skip-git-repo-check|--json) shift ;;
    *) shift ;;
  esac
done
echo '{"type":"thread.started"}'
echo '{"type":"turn.failed","error":{"message":"rate_limit_exceeded: quota exhausted"}}'
exit 1
EOF
chmod +x "$STUB"

# --- лічильник-нотифаєр: підміна CC_NOTIFY ---
COUNTER_FILE="$TMP/notify-count"
: > "$COUNTER_FILE"
NOTIFY_STUB="$TMP/counting-notify.sh"
cat > "$NOTIFY_STUB" <<EOF
#!/bin/sh
echo "call: \$*" >> "$COUNTER_FILE"
exit 0
EOF
chmod +x "$NOTIFY_STUB"

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm init

TASK1="$TMP/task1.md"; echo "task run1 {RUN_ID}" > "$TASK1"
PLAN="$TMP/plan.txt"
echo "run1|none|$TASK1|sonnet|codex" > "$PLAN"

STUBLOG="$TMP/codex-model-calls.log"; : > "$STUBLOG"
COUNTER="$TMP/call-counter"; echo 0 > "$COUNTER"

# --- 1. лічильник має зрости ---
mkdir -p "$TMP/runs-1"
CC_RUNS="$TMP/runs-1" CC_CODEX_BIN="$STUB" CC_CODEX_STUB_LOG="$STUBLOG" \
  CC_CODEX_STUB_COUNTER="$COUNTER" CC_TEST_SCENARIO=quota \
  CC_NOTIFY="$NOTIFY_STUB" CC_WEEK_LOCK="$TMP/no-week-lock-1" \
  sh "$BIN/cc-chain.sh" "$REPO" "$PLAN" notify-iso-1 >"$TMP/chain-1.out" 2>&1
RC=$?
[ "$RC" = "3" ] || { echo "FAIL: очікував exit 3 (session limit), отримав $RC ($(cat "$TMP/chain-1.out"))"; FAIL=1; }
N=$(wc -l < "$COUNTER_FILE" | tr -d ' ')
[ "$N" -gt 0 ] || { echo "FAIL: лічильник-нотифаєр (CC_NOTIFY) жодного разу не викликаний"; FAIL=1; }

# --- 2. під strace -f: реальний bin/cc-notify.sh НЕ повинен execve'нутись ---
if command -v strace >/dev/null 2>&1; then
  REPO2="$TMP/repo2"
  mkdir -p "$REPO2"
  git -C "$REPO2" init -q
  git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
  echo x > "$REPO2/f"
  git -C "$REPO2" add f
  git -C "$REPO2" commit -qm init

  : > "$STUBLOG"; echo 0 > "$COUNTER"
  mkdir -p "$TMP/runs-2"
  STRACE_OUT="$TMP/strace.out"
  CC_RUNS="$TMP/runs-2" CC_CODEX_BIN="$STUB" CC_CODEX_STUB_LOG="$STUBLOG" \
    CC_CODEX_STUB_COUNTER="$COUNTER" CC_TEST_SCENARIO=quota \
    CC_NOTIFY="$NOTIFY_STUB" CC_WEEK_LOCK="$TMP/no-week-lock-2" \
    strace -f -s 300 -e trace=execve -o "$STRACE_OUT" \
    sh "$BIN/cc-chain.sh" "$REPO2" "$PLAN" notify-iso-2 >"$TMP/chain-2.out" 2>&1
  if grep -qF "$REAL_NOTIFY" "$STRACE_OUT"; then
    echo "FAIL: реальний $REAL_NOTIFY був execve'нутий (CC_NOTIFY проігноровано)"; FAIL=1
  fi
  grep -qF "$NOTIFY_STUB" "$STRACE_OUT" || { echo "FAIL: strace не бачить жодного execve лічильника-нотифаєра"; FAIL=1; }
else
  echo "SKIP: strace недоступний у цьому середовищі — крок 2 (execve-трейс) пропущено, крок 1 (лічильник) достатній"
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: cc-chain.sh поважає CC_NOTIFY — лічильник викликаний, реальний cc-notify.sh не execve'нутий"
