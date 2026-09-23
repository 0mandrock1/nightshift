#!/bin/sh
# Доводить: підозріла verify-cmd (§8 SKILL.md денилист) -> план невалідний,
# драйвер падає ДО будь-якого спавну (Блокер 2 рев'ю).
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

FAIL=0

try_plan(){
  DESC=$1; VERIFY=$2; EXPECT_FAIL=$3
  PLAN="$TMP/plan-$$.txt"
  TASK="$TMP/task-$$.md"
  echo "task" > "$TASK"
  printf 'lane0|%s|%s|haiku|none\n' "$TASK" "$VERIFY" > "$PLAN"
  CC_RUNS_DIR="$TMP/runs" CC_SWARMS_DIR="$TMP/swarms" CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
    CC_PG_CREDS="$TMP/no-creds" \
    DRYRUN=1 sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" "denylist-$$" >/dev/null 2>&1
  RC=$?
  if [ "$EXPECT_FAIL" = "1" ]; then
    if [ "$RC" = "1" ]; then
      echo "OK: '$DESC' відхилено (exit 1)"
    else
      echo "FAIL: '$DESC' мав відхилятись (exit 1), отримав $RC"; FAIL=1
    fi
  else
    if [ "$RC" = "0" ]; then
      echo "OK: '$DESC' прийнято (exit 0)"
    else
      echo "FAIL: '$DESC' мав прийматись (exit 0), отримав $RC"; FAIL=1
    fi
  fi
  rm -f "$PLAN" "$TASK"
}

try_plan "true"            "true"                 1
try_plan ":"                ":"                    1
try_plan "exit 0"          "exit 0"               1
try_plan "echo ok"         "echo ok"              1
try_plan "голий echo"      "echo щось інше"       1
try_plan "echo && тест"    "echo hi && test -f f" 0
try_plan "справжній grep"  "grep -q X f"           0

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: денилист verify-cmd ловить фіктивні команди, пропускає реальні"
