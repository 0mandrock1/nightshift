#!/bin/sh
# Гейт тижневого бюджету (<5 % лишилось) міряє usage Claude: claude-ланцюг
# він зупиняє (exit 5), ланцюг лише з codex-кроків — пропускає.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0
export CC_NOTIFY="$HERE/fixtures/notify-null.sh" CC_WEEK_LOCK="$TMP/no-lock" \
  CC_USAGE_CLI="$HERE/fixtures/usage-cli-high.js" CC_CODEX_BIN=/bin/false
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf 'тест\n' > "$TMP/task.md"
printf 's1|none|%s|sonnet\n' "$TMP/task.md" > "$TMP/claude.plan"
printf 's1|none|%s|gpt-6-luna|codex\n' "$TMP/task.md" > "$TMP/codex.plan"

mkdir -p "$TMP/r1"; CC_RUNS="$TMP/r1" sh "$BIN/cc-chain.sh" "$REPO" "$TMP/claude.plan" g1 > "$TMP/g1.out" 2>&1; RC=$?
[ "$RC" = 5 ] || { echo "FAIL: claude-ланцюг мав зупинити гейт тижня (exit 5), отримав $RC"; FAIL=1; }
cat "$TMP/g1.out" "$TMP"/r1/*.log 2>/dev/null | grep -q "ГЕЙТ ТИЖНЯ" || { echo "FAIL: нема повідомлення гейта в claude-ланцюгу"; FAIL=1; }

mkdir -p "$TMP/r2"; CC_RUNS="$TMP/r2" sh "$BIN/cc-chain.sh" "$REPO" "$TMP/codex.plan" g2 > "$TMP/g2.out" 2>&1; RC=$?
[ "$RC" != 5 ] || { echo "FAIL: codex-ланцюг не мав зупинятись гейтом тижня"; FAIL=1; }
cat "$TMP/g2.out" "$TMP"/r2/*.log 2>/dev/null | grep -q "ГЕЙТ ТИЖНЯ" && { echo "FAIL: codex-ланцюг показав ГЕЙТ ТИЖНЯ"; FAIL=1; }

[ "$FAIL" = 0 ] || exit 1
echo "OK: гейт тижня зупиняє claude-ланцюг і пропускає ланцюг лише з codex-кроків"
