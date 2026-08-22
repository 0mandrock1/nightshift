#!/bin/sh
# Доводить, що LANE_TIMEOUT реально вбиває завислий лейн замість того, щоб
# вішати рій назавжди, і що лейн отримує статус `timeout`, не блокуючи решту.
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

STUB="$TMP/stub-run.sh"
cat > "$STUB" <<EOF
#!/bin/sh
D=\$1
SLUG=\$(basename "\$D")
SLUG=\${SLUG#timeout-test-}
if [ "\$SLUG" = "hang" ]; then
  sleep 30
  echo "RESULT: ok" > "\$D/out.log"
  echo 0 > "\$D/exit_code"
  exit 0
fi
echo "RESULT: ok" > "\$D/out.log"
echo 0 > "\$D/exit_code"
exit 0
EOF
chmod +x "$STUB"

PLAN="$TMP/plan.txt"
echo "task" > "$TMP/task-fast.md"
echo "task" > "$TMP/task-hang.md"
cat > "$PLAN" <<EOF
fast|$TMP/task-fast.md|test -f f|haiku|none
hang|$TMP/task-hang.md|test -f f|haiku|none
EOF

START=$(date +%s)
CC_RUNS_DIR="$TMP/runs" CC_SWARMS_DIR="$TMP/swarms" CC_RUN_SH="$STUB" \
  CC_PG_CREDS="$TMP/no-creds" \
  CC_NOTIFY=/bin/true MAXPAR=2 LANE_TIMEOUT=3 \
  sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" timeout-test
RC=$?
ELAPSED=$(( $(date +%s) - START ))

FAIL=0
if [ "$RC" != "2" ]; then echo "FAIL: очікував exit 2 (timeout=fail), отримав $RC"; FAIL=1; fi
if [ "$ELAPSED" -ge 25 ]; then echo "FAIL: рій чекав $ELAPSED с — таймаут не спрацював (мало б спинитись за ~3-5с)"; FAIL=1; fi

MANIFEST="$TMP/swarms/timeout-test/manifest.tsv"
if ! grep -qE '^hang.*	timeout	' "$MANIFEST" 2>/dev/null; then
  echo "FAIL: hang не позначено timeout у маніфесті"; cat "$MANIFEST" 2>&1; FAIL=1
fi
if ! grep -qE '^fast.*	ok	' "$MANIFEST" 2>/dev/null; then
  echo "FAIL: fast не позначено ok у маніфесті"; FAIL=1
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: hang вбито за LANE_TIMEOUT (elapsed=${ELAPSED}s), fast завершився ok"
