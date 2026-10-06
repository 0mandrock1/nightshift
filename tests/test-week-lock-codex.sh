#!/bin/sh
# Тижневий лок міряє лише usage Claude: codex-ланцюг і codex-ран його обходять,
# claude / змішаний / нечитабельний plan — ні (fail-closed).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0
LOCK="$TMP/.week-locked"; echo "locked test" > "$LOCK"
export CC_NOTIFY="$HERE/fixtures/notify-null.sh" CC_WEEK_LOCK="$LOCK" CC_CODEX_BIN=/bin/false

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf 'тест\n' > "$TMP/task.md"

plan() { printf '%s\n' "$2" > "$TMP/$1.plan"; }
chain() { # <plan-name> <runs-dir>
  mkdir -p "$TMP/$2"
  CC_RUNS="$TMP/$2" sh "$BIN/cc-chain.sh" "$REPO" "$TMP/$1.plan" "t-$1" > "$TMP/$1.out" 2>&1
  echo $?
}
expect_locked() { # <name> <rc>
  [ "$2" = 5 ] || { echo "FAIL: $1 мав відмовити локом (exit 5), отримав $2"; FAIL=1; }
  grep -q "тижневий лок" "$TMP/$1.out" || { echo "FAIL: $1 без повідомлення про лок"; FAIL=1; }
}

plan claude "s1|none|$TMP/task.md|sonnet"
expect_locked claude "$(chain claude r1)"

plan mixed "s1|none|$TMP/task.md|gpt-6-luna|codex
s2|none|$TMP/task.md|sonnet|claude"
expect_locked mixed "$(chain mixed r2)"

rm -f "$TMP/nope.plan"
mkdir -p "$TMP/r3"
CC_RUNS="$TMP/r3" sh "$BIN/cc-chain.sh" "$REPO" "$TMP/nope.plan" t-nope > "$TMP/nope.out" 2>&1; RC=$?
expect_locked nope "$RC"

plan codex "s1|none|$TMP/task.md|gpt-6-luna|codex"
RC=$(chain codex r4)
[ "$RC" != 5 ] || { echo "FAIL: codex-ланцюг не мав зупинятись локом"; FAIL=1; }
grep -q "тижневий лок" "$TMP/codex.out" && { echo "FAIL: codex-ланцюг показав повідомлення про лок"; FAIL=1; }
grep -q "backend=codex" "$TMP/codex.out" || grep -rq "backend=codex" "$TMP/r4" 2>/dev/null || { echo "FAIL: codex-ланцюг не дійшов до спавну codex"; FAIL=1; }

# cc-run.sh: codex обходить лок, claude — ні
mkdir -p "$TMP/runs-run/x1"
CC_RUNS="$TMP/runs-run" sh "$BIN/cc-run.sh" "$TMP/runs-run/x1" none "" claude > "$TMP/run-claude.out" 2>&1; RC=$?
expect_locked run-claude "$RC"
CC_RUNS="$TMP/runs-run" sh "$BIN/cc-run.sh" "$TMP/runs-run/x1" none "" codex > "$TMP/run-codex.out" 2>&1; RC=$?
[ "$RC" != 5 ] || { echo "FAIL: cc-run.sh codex не мав зупинятись локом"; FAIL=1; }
grep -q "тижневий лок" "$TMP/run-codex.out" && { echo "FAIL: cc-run.sh codex показав лок"; FAIL=1; }

[ "$FAIL" = 0 ] || exit 1
echo "OK: тижневий лок діє на claude/змішані/нечитабельні плани й обходиться codex-бекендом"
