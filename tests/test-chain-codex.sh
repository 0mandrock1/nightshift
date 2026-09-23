#!/bin/sh
# Паритет BACKEND=codex у cc-chain.sh: фейковий CC_CODEX_BIN (той самий підхід
# stub, що й tests/test-codex-backend.sh, але тут гонить ланцюг напряму, не
# cc-run.sh — довести, що mapping/session-limit/RESULT-парсинг, які cc-chain.sh
# зробив САМ (без делегування в cc-run.sh), реально працюють end-to-end).
#   A. два рани ланцюга на codex: другий продовжує гілку/коміти першого
#      (git-безперервність, не два незалежні checkout з одного base)
#   B. quota на першому рані -> ланцюг спиняється exit 3, другий рядок плану
#      НЕ спавниться
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

STUBLOG="$TMP/codex-model-calls.log"
: > "$STUBLOG"
COUNTER="$TMP/call-counter"
echo 0 > "$COUNTER"

STUB="$TMP/fake-codex"
cat > "$STUB" <<'EOF'
#!/bin/sh
# Фейковий `codex` CLI: парсить -m/-o з argv `codex exec`, логує отриману
# модель у $CC_CODEX_STUB_LOG, лишає окремий файл-маркер у CWD (доводить, що
# наступний ран ланцюга бачить коміт цього рану), поведінку задає
# $CC_TEST_SCENARIO.
set -u
MODEL=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    exec) shift ;;
    -m) MODEL=$2; shift 2 ;;
    -o) OUT=$2; shift 2 ;;
    -s) shift 2 ;;
    -C) shift 2 ;;
    --add-dir) shift 2 ;;
    -c) shift 2 ;;
    --skip-git-repo-check|--json) shift ;;
    *) shift ;;
  esac
done
echo "$MODEL" >> "${CC_CODEX_STUB_LOG:?}"
N=$(cat "${CC_CODEX_STUB_COUNTER:?}")
N=$((N+1))
echo "$N" > "$CC_CODEX_STUB_COUNTER"

case "${CC_TEST_SCENARIO:-}" in
  ok)
    : > "call$N.txt"
    echo '{"type":"thread.started"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}'
    printf 'RESULT: ok\nNOTES: stub ok call %s\n' "$N" > "$OUT"
    exit 0
    ;;
  quota)
    echo '{"type":"thread.started"}'
    echo '{"type":"turn.failed","error":{"message":"rate_limit_exceeded: quota exhausted"}}'
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$STUB"

FAIL=0

# --- A. два рани, другий продовжує гілку/коміти першого ---
REPO_A="$TMP/repo-a"
mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
git -C "$REPO_A" config user.email t@t; git -C "$REPO_A" config user.name t
echo x > "$REPO_A/f"
git -C "$REPO_A" add f
git -C "$REPO_A" commit -qm init

TASK1="$TMP/task1.md"; echo "task run1 {RUN_ID}" > "$TASK1"
TASK2="$TMP/task2.md"; echo "task run2 {RUN_ID}" > "$TASK2"
PLAN_A="$TMP/plan-a.txt"
{
  echo "run1|none|$TASK1|sonnet|codex"
  echo "run2|none|$TASK2|sonnet|codex"
} > "$PLAN_A"

: > "$STUBLOG"; echo 0 > "$COUNTER"
mkdir -p "$TMP/runs-a"
CC_RUNS="$TMP/runs-a" CC_CODEX_BIN="$STUB" CC_CODEX_STUB_LOG="$STUBLOG" \
  CC_CODEX_STUB_COUNTER="$COUNTER" CC_TEST_SCENARIO=ok CC_NOTIFY=/bin/true \
  CC_WEEK_LOCK="$TMP/no-week-lock-a" \
  sh "$BIN/cc-chain.sh" "$REPO_A" "$PLAN_A" chain-codex-a >"$TMP/chain-a.out" 2>&1
RC=$?
[ "$RC" = "0" ] || { echo "FAIL: A очікував exit 0, отримав $RC ($(cat "$TMP/chain-a.out"))"; FAIL=1; }
LINES=$(wc -l < "$STUBLOG" | tr -d ' ')
[ "$LINES" = "2" ] || { echo "FAIL: A очікував 2 виклики codex-stub, отримав $LINES"; FAIL=1; }
if [ -s "$STUBLOG" ]; then
  UNIQ=$(sort -u "$STUBLOG" | tr -d '\n')
  [ "$UNIQ" = "gpt-6-luna" ] || { echo "FAIL: A sonnet мав мапитись на gpt-6-luna, stub бачив '$UNIQ'"; FAIL=1; }
fi
# Продовження: гілка другого рану має містити коміт з файлом першого рану
FINAL_BRANCH=$(git -C "$REPO_A" rev-parse --abbrev-ref HEAD)
case "$FINAL_BRANCH" in
  cc/run2-*) : ;;
  *) echo "FAIL: A фінальна гілка мала бути cc/run2-*, отримав $FINAL_BRANCH"; FAIL=1 ;;
esac
LOG_N=$(git -C "$REPO_A" log --oneline | wc -l | tr -d ' ')
[ "$LOG_N" = "3" ] || { echo "FAIL: A очікував 3 коміти (init + 2 авто-коміти), отримав $LOG_N"; FAIL=1; }
[ -f "$REPO_A/call1.txt" ] || { echo "FAIL: A маркер run1 (call1.txt) відсутній у фінальному дереві"; FAIL=1; }
[ -f "$REPO_A/call2.txt" ] || { echo "FAIL: A маркер run2 (call2.txt) відсутній у фінальному дереві"; FAIL=1; }

# --- B. quota на першому рані -> ланцюг exit 3, run2 не спавниться ---
REPO_B="$TMP/repo-b"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" config user.email t@t; git -C "$REPO_B" config user.name t
echo x > "$REPO_B/f"
git -C "$REPO_B" add f
git -C "$REPO_B" commit -qm init

PLAN_B="$TMP/plan-b.txt"
{
  echo "run1|none|$TASK1|sonnet|codex"
  echo "run2|none|$TASK2|sonnet|codex"
} > "$PLAN_B"

: > "$STUBLOG"; echo 0 > "$COUNTER"
mkdir -p "$TMP/runs-b"
CC_RUNS="$TMP/runs-b" CC_CODEX_BIN="$STUB" CC_CODEX_STUB_LOG="$STUBLOG" \
  CC_CODEX_STUB_COUNTER="$COUNTER" CC_TEST_SCENARIO=quota CC_NOTIFY=/bin/true \
  CC_WEEK_LOCK="$TMP/no-week-lock-b" \
  sh "$BIN/cc-chain.sh" "$REPO_B" "$PLAN_B" chain-codex-b >"$TMP/chain-b.out" 2>&1
RC=$?
[ "$RC" = "3" ] || { echo "FAIL: B очікував exit 3, отримав $RC ($(cat "$TMP/chain-b.out"))"; FAIL=1; }
LINES_B=$(wc -l < "$STUBLOG" | tr -d ' ')
[ "$LINES_B" = "1" ] || { echo "FAIL: B run2 не мав спавнитись, викликів codex-stub: $LINES_B"; FAIL=1; }
RUN1DIR=$(find "$TMP/runs-b" -maxdepth 1 -name 'run1-*' -type d | head -1)
[ -n "$RUN1DIR" ] && grep -q "session limit" "$RUN1DIR/out.log" 2>/dev/null || { echo "FAIL: B quota не позначено як session limit у run1/out.log"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: cc-chain.sh codex-бекенд — два рани продовжують гілку одне одного, quota на першому -> exit 3"
