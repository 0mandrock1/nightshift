#!/bin/sh
# Паритет BACKEND=codex у cc-run.sh: фейковий CC_CODEX_BIN замість реального
# codex, керований через CC_TEST_SCENARIO (ok/fail/quota). Кейси:
#   ok      -> exit 0, RESULT ok зі stub-таки last-message.txt дописаний в out.log
#   fail    -> exit 2, RESULT fail
#   quota   -> turn.failed/rate-limit в events.jsonl -> exit 3 (session limit)
#   sol     -> model=gpt-6-sol без CC_OPUS_REASON -> exit 6, codex НЕ спавниться
#   sonnet  -> model=sonnet мапиться на -m gpt-6-luna (перевірка через stub-лог)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm init

STUBLOG="$TMP/codex-model-calls.log"
: > "$STUBLOG"

STUB="$TMP/fake-codex"
cat > "$STUB" <<'EOF'
#!/bin/sh
# Фейковий `codex` CLI: парсить -m/-o з argv codex exec, логує отриману
# модель у $CC_CODEX_STUB_LOG, поведінку задає $CC_TEST_SCENARIO.
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

case "${CC_TEST_SCENARIO:-}" in
  ok)
    echo '{"type":"thread.started"}'
    echo '{"type":"turn.started"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}'
    printf 'RESULT: ok\nNOTES: stub ok\n' > "$OUT"
    exit 0
    ;;
  fail)
    echo '{"type":"thread.started"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5}}'
    printf 'RESULT: fail\nNOTES: stub fail\n' > "$OUT"
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
RUNS="$TMP/runs"

run_case() {
  ID=$1; MODEL=$2; SCENARIO=$3; REASON=${4:-}
  D="$RUNS/$ID"
  mkdir -p "$D"
  echo "task $ID" > "$D/task.md"
  ( cd "$REPO" && \
    CC_RUNS="$RUNS" CC_CODEX_BIN="$STUB" CC_CODEX_STUB_LOG="$STUBLOG" \
    CC_TEST_SCENARIO="$SCENARIO" CC_NOTIFY=/bin/true \
    CC_OPUS_REASON="$REASON" \
    sh "$BIN/cc-run.sh" "$D" none "$MODEL" codex ) >/dev/null 2>&1
  return $?
}

# --- ok ---
run_case case-ok sonnet ok; RC=$?
[ "$RC" = "0" ] || { echo "FAIL: ok-кейс очікував exit 0, отримав $RC"; FAIL=1; }
grep -q "RESULT: ok" "$RUNS/case-ok/out.log" 2>/dev/null || { echo "FAIL: RESULT ok не дописано в out.log"; FAIL=1; }
[ -s "$RUNS/case-ok/events.jsonl" ] || { echo "FAIL: events.jsonl порожній/відсутній"; FAIL=1; }

# --- fail ---
run_case case-fail sonnet fail; RC=$?
[ "$RC" = "2" ] || { echo "FAIL: fail-кейс очікував exit 2, отримав $RC"; FAIL=1; }
grep -q "RESULT: fail" "$RUNS/case-fail/out.log" 2>/dev/null || { echo "FAIL: RESULT fail не дописано в out.log"; FAIL=1; }

# --- quota -> 3 ---
run_case case-quota sonnet quota; RC=$?
[ "$RC" = "3" ] || { echo "FAIL: quota-кейс очікував exit 3, отримав $RC"; FAIL=1; }
grep -q "session limit" "$RUNS/case-quota/out.log" 2>/dev/null || { echo "FAIL: quota не позначено як session limit"; FAIL=1; }

# --- gpt-6-sol без CC_OPUS_REASON -> 6, codex не спавниться ---
: > "$STUBLOG"
run_case case-sol gpt-6-sol ok ""; RC=$?
[ "$RC" = "6" ] || { echo "FAIL: sol без причини очікував exit 6, отримав $RC"; FAIL=1; }
[ -s "$STUBLOG" ] && { echo "FAIL: codex-stub спавнився попри відсутній CC_OPUS_REASON"; FAIL=1; }

# --- sonnet -> -m gpt-6-luna ---
: > "$STUBLOG"
run_case case-map sonnet ok; RC=$?
[ "$RC" = "0" ] || { echo "FAIL: mapping-кейс очікував exit 0, отримав $RC"; FAIL=1; }
LOGGED=$(cat "$STUBLOG" 2>/dev/null)
[ "$LOGGED" = "gpt-6-luna" ] || { echo "FAIL: sonnet мав мапитись на gpt-6-luna, stub отримав '$LOGGED'"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: codex-бекенд — ok/fail/quota->3/sol-без-причини->6/sonnet->gpt-6-luna"
