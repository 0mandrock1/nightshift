#!/bin/sh
# Бакет model×kind estimator v2 реально спрацьовує з обгорток (27.09 finding):
# cc-chain.sh кликав cc-estimate.sh без --kind, а фолбек брав basename
# task-файлу — майже завжди буквально "task.md" -> KIND=task, повз історію
# конкретного типу задачі (tv/dt/reyfo/...). Кейси:
#   (a) --task <run-dir>/tv-.../task.md БЕЗ --kind -> KIND=tv (з імені run-dir,
#       не з literal "task.md")
#   (b) --kind dt перебиває будь-який фолбек
#   (c) кожен виклик cc-estimate.sh у bin/*.sh передає --kind (grep-контракт,
#       щоб регрес на кшталт cc-chain.sh:363 не повернувся тихо)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

CC_USAGE_CLI="$HERE/fixtures/usage-cli-stub.js"
export CC_USAGE_CLI
# Без docker/creds-pg.env естіматор best-effort пропускає БД-запити (MK_N=M_N=0) —
# KIND у VARS2 друкується незалежно від цього, саме його й перевіряємо.
CC_PG_CREDS="$TMP/no-such-creds.env"
export CC_PG_CREDS

RUNDIR="$TMP/tv-20260101-000000"
mkdir -p "$RUNDIR"
echo "тестова задача" > "$RUNDIR/task.md"

# --- (a) без --kind: KIND має братись з ІМЕНІ RUN-DIR (tv-20260101-000000 -> tv),
# не з basename файлу "task.md" (це і був баг) ---
VARS2_A=$(sh "$BIN/cc-estimate.sh" --task "$RUNDIR/task.md" --model sonnet 2>/dev/null | grep '^VARS2:')
echo "$VARS2_A" | grep -q 'KIND=tv ' || { echo "FAIL(a): очікував KIND=tv, отримав: $VARS2_A"; FAIL=1; }

# --- (b) --kind dt перебиває фолбек ---
VARS2_B=$(sh "$BIN/cc-estimate.sh" --task "$RUNDIR/task.md" --model sonnet --kind dt 2>/dev/null | grep '^VARS2:')
echo "$VARS2_B" | grep -q 'KIND=dt ' || { echo "FAIL(b): очікував KIND=dt, отримав: $VARS2_B"; FAIL=1; }

# --- (c) кожен виклик cc-estimate.sh у bin/*.sh передає --kind ---
# (виключаємо сам cc-estimate.sh — там немає self-виклику; коментарі теж
# не рахуємо — беремо лише реальні рядки виклику "sh ... cc-estimate.sh").
CALLS=$(grep -nE 'sh "\$[A-Za-z_]+(/cc-estimate\.sh|"/cc-estimate\.sh)|cc-estimate\.sh --task' "$BIN"/*.sh \
  | grep -v '^\S*bin/cc-estimate\.sh:' \
  | grep -v '^\s*#' )
if [ -z "$CALLS" ]; then
  echo "FAIL(c): grep не знайшов жодного виклику cc-estimate.sh у bin/ — контракт тесту протух"
  FAIL=1
else
  echo "$CALLS" | while IFS= read -r line; do
    case "$line" in
      *'--kind'*) : ;;
      *)
        echo "FAIL(c): виклик без --kind: $line"
        exit 1
        ;;
    esac
  done || FAIL=1
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: KIND з run-dir без --kind (a), --kind перебиває (b), усі виклики в bin/ передають --kind (c)"
