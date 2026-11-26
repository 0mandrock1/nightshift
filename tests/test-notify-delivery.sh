#!/bin/sh
# Нотифікації cc-ранів не губляться мовчки (регрес 26.11, neonsign-*):
#   (a) cc-notify.sh: на не-200 у stderr є http і api=<description> з тіла,
#       фолбек plain шлеться, токена у виводі нема, exit 0;
#   (b) cc-chain.sh: провал доставки (фейковий curl -> 500) лишає curl_rc/http у
#       $CHAIN.notify-debug.log і рядок у лозі ланцюга; exit-код рану не змінено;
#   (c) cc-chain.sh: SIGTERM ззовні посеред кроку -> exit 143 одразу (не після
#       кінця claude), exit_code=143 і fail_reason=KILLED у run-dir кроку,
#       повідомлення "вбито", дочірній claude прибито.
# Реальний Telegram не викликається: curl підмінено через PATH, токен фейковий.
set -u
export CC_NOTIFY_REFRESH=0
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0
TOKEN=FAKETOKEN-0000-must-not-leak

export CC_USAGE_CLI=${CC_USAGE_CLI:-"$HERE/fixtures/usage-cli-stub.js"}
export CC_PG_CREDS="$TMP/no-creds" CC_WEEK_LOCK="$TMP/no-week-lock"
export CC_CLAUDE_PROJECTS="$TMP/claude-projects"

printf 'BOT_TOKEN=%s\nOWNER_CHAT_ID=1\n' "$TOKEN" > "$TMP/notify.env"

# Фейковий curl: http-код із CURL_CODES (по черзі для html/plain), тіло -> -o.
FAKEPATH="$TMP/fakepath"; mkdir -p "$FAKEPATH"
cat > "$FAKEPATH/curl" <<'EOF'
#!/bin/sh
out=/dev/null
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
n=$(cat "$CURL_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$CURL_STATE"
code=$(echo "$CURL_CODES" | cut -d, -f"$n"); [ -n "$code" ] || code=200
if [ "$code" = 200 ]; then echo '{"ok":true}' > "$out"
else printf '{"ok":false,"error_code":%s,"description":"Bad Request: fake %s"}' "$code" "$code" > "$out"; fi
printf '%s' "$code"
EOF
chmod +x "$FAKEPATH/curl"

# --- (a) cc-notify.sh напряму ---
echo 0 > "$TMP/curl-a"
ERR=$(PATH="$FAKEPATH:$PATH" CURL_STATE="$TMP/curl-a" CURL_CODES=400,200 \
  CC_NOTIFY_ENV="$TMP/notify.env" sh "$BIN/cc-notify.sh" "<b>x</b>" 2>&1 >/dev/null)
RC=$?
[ "$RC" = 0 ] || { echo "FAIL(a): cc-notify exit $RC, очікував 0"; FAIL=1; }
echo "$ERR" | grep -q 'html: curl_rc=0 http=400 api=Bad Request: fake 400' || { echo "FAIL(a): нема http=400 з описом API: $ERR"; FAIL=1; }
echo "$ERR" | grep -q 'plain: curl_rc=0 http=200$' || { echo "FAIL(a): нема plain http=200: $ERR"; FAIL=1; }
echo "$ERR" | grep -q "$TOKEN" && { echo "FAIL(a): токен у виводі"; FAIL=1; }

# Тестове репо + bin з реальним cc-notify.sh (через обгортку з фейковим curl).
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm init
NOTIFY_WRAP="$TMP/notify-wrap.sh"
cat > "$NOTIFY_WRAP" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/notify-texts"
PATH="$FAKEPATH:\$PATH" CURL_STATE="$TMP/curl-chain" CURL_CODES="\${CURL_CODES:-500,500}" \\
  CC_NOTIFY_ENV="$TMP/notify.env" exec sh "$BIN/cc-notify.sh" "\$@"
EOF
chmod +x "$NOTIFY_WRAP"

# --- (b) ланцюг, ран ok, доставка падає 500 ---
CLAUDE_OK="$TMP/claude-ok.sh"
cat > "$CLAUDE_OK" <<EOF
#!/bin/sh
echo y >> "$REPO/f"
printf 'CHANGED: f\nRESULT: ok\n'
EOF
chmod +x "$CLAUDE_OK"
echo "s1|none|$TMP/task.md|haiku|claude" > "$TMP/plan-b.txt"; echo "task {RUN_ID}" > "$TMP/task.md"
mkdir -p "$TMP/runs-b"; : > "$TMP/notify-texts"
CURL_CODES=500,500 CC_RUNS="$TMP/runs-b" CC_CLAUDE_BIN="$CLAUDE_OK" CC_NOTIFY="$NOTIFY_WRAP" CC_RUN_TIMEOUT_S=30 \
  sh "$BIN/cc-chain.sh" "$REPO" "$TMP/plan-b.txt" nb >"$TMP/chain-b.out" 2>&1
RC=$?
[ "$RC" = 0 ] || { echo "FAIL(b): ланцюг exit $RC, очікував 0 ($(tail -5 "$TMP/chain-b.out"))"; FAIL=1; }
NLOG=$(ls "$TMP"/runs-b/nb-*.log.notify-debug.log 2>/dev/null | head -1)
CLOG=$(ls "$TMP"/runs-b/nb-*.log 2>/dev/null | grep -v '\.log\.' | head -1)
[ -n "$NLOG" ] && grep -q 'html: curl_rc=0 http=500 api=Bad Request: fake 500' "$NLOG" \
  || { echo "FAIL(b): нема curl_rc/http=500 у notify-debug.log (${NLOG:-нема файлу})"; FAIL=1; }
[ -n "$NLOG" ] && grep -q '^notify rc=0' "$NLOG" || { echo "FAIL(b): нема 'notify rc=0' у $NLOG"; FAIL=1; }
[ -n "$CLOG" ] && grep -q 'Telegram не підтвердив доставку' "$CLOG" || { echo "FAIL(b): нема попередження в лозі ланцюга"; FAIL=1; }
grep -rq "$TOKEN" "$TMP/runs-b" "$TMP/chain-b.out" && { echo "FAIL(b): токен у логах"; FAIL=1; }
grep -q 'ланцюг пройшов' "$TMP/notify-texts" || { echo "FAIL(b): фінальне повідомлення не відправлялось"; FAIL=1; }

# --- (c) SIGTERM ланцюга посеред кроку ---
CLAUDE_SLOW="$TMP/claude-slow.sh"
cat > "$CLAUDE_SLOW" <<EOF
#!/bin/sh
echo \$\$ > "$TMP/claude.pid"
sleep 60
echo 'RESULT: ok'
EOF
chmod +x "$CLAUDE_SLOW"
echo "k1|none|$TMP/task.md|haiku|claude" > "$TMP/plan-c.txt"
mkdir -p "$TMP/runs-c"; : > "$TMP/notify-texts"; rm -f "$TMP/curl-chain"
# setsid: власна група процесів, щоб сигнал не зачепив оточення тесту.
CURL_CODES=200 CC_RUNS="$TMP/runs-c" CC_CLAUDE_BIN="$CLAUDE_SLOW" CC_NOTIFY="$NOTIFY_WRAP" CC_RUN_TIMEOUT_S=120 \
  setsid sh -c 'echo $$ > "$1"; exec sh "$2" "$3" "$4" nk' _ "$TMP/chain.pid" "$BIN/cc-chain.sh" "$REPO" "$TMP/plan-c.txt" \
  >"$TMP/chain-c.out" 2>&1 &
i=0; until [ -s "$TMP/claude.pid" ]; do i=$((i+1)); [ $i -ge 150 ] && break; sleep 0.2; done
CHAIN_PID=$(cat "$TMP/chain.pid" 2>/dev/null)
CPID=$(cat "$TMP/claude.pid" 2>/dev/null)
if [ -z "$CPID" ] || [ -z "$CHAIN_PID" ]; then
  echo "FAIL(c): фейковий claude не стартував ($(tail -5 "$TMP/chain-c.out"))"; FAIL=1
else
  T0=$(date +%s)
  kill -TERM "$CHAIN_PID"
  wait $!; RC=$?
  DT=$(( $(date +%s) - T0 ))
  [ "$RC" = 143 ] || { echo "FAIL(c): ланцюг exit $RC, очікував 143"; FAIL=1; }
  [ "$DT" -lt 30 ] || { echo "FAIL(c): ланцюг завершився через ${DT}s — trap чекав кінця claude"; FAIL=1; }
  SD=$(ls -d "$TMP"/runs-c/k1-* 2>/dev/null | grep -v '\.log' | head -1)
  [ "$(cat "$SD/exit_code" 2>/dev/null)" = 143 ] || { echo "FAIL(c): exit_code у run-dir '$(cat "$SD/exit_code" 2>/dev/null)', очікував 143"; FAIL=1; }
  [ "$(cat "$SD/fail_reason" 2>/dev/null)" = KILLED ] || { echo "FAIL(c): fail_reason не KILLED"; FAIL=1; }
  grep -q 'ланцюг вбито (SIGTERM)' "$TMP/notify-texts" || { echo "FAIL(c): нема повідомлення про вбивство"; FAIL=1; }
  grep -q 'exit 143' "$TMP/notify-texts" || { echo "FAIL(c): у повідомленні нема exit 143"; FAIL=1; }
  CLOG=$(ls "$TMP"/runs-c/nk-*.log 2>/dev/null | grep -v '\.log\.' | head -1)
  grep -q 'KILLED — ланцюг отримав SIGTERM, exit 143' "$CLOG" || { echo "FAIL(c): нема KILLED у лозі ланцюга"; FAIL=1; }
  i=0; while kill -0 "$CPID" 2>/dev/null; do i=$((i+1)); [ $i -ge 25 ] && break; sleep 0.2; done
  kill -0 "$CPID" 2>/dev/null && { echo "FAIL(c): фейковий claude $CPID живий після вбивства ланцюга"; kill "$CPID"; FAIL=1; }
  ls "$TMP"/runs-c/.lock-* >/dev/null 2>&1 && { echo "FAIL(c): лок-теки лишились"; FAIL=1; }
fi

[ "$FAIL" = 0 ] && echo "test-notify-delivery: OK"
exit "$FAIL"
