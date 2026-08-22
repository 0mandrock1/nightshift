#!/bin/sh
# Доводить, що session limit (exit 3 з cc-run.sh) реально зупиняє спавн решти
# лейнів (регрес: LIMIT_HIT виставлявся в сабшелі й батько його не бачив).
# 6 лейнів, MAXPAR=1 (детермінізм порядку), підставний runner повертає 3 на
# другому лейні (lane1) — перевірка, що lane2..lane5 НЕ стартували і рій
# завершився exit 3.
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

STARTED="$TMP/started"
mkdir -p "$STARTED"

STUB="$TMP/stub-run.sh"
cat > "$STUB" <<EOF
#!/bin/sh
D=\$1
SLUG=\$(basename "\$D")
SLUG=\${SLUG#limit-test-}
: > "$STARTED/\$SLUG"
if [ "\$SLUG" = "lane1" ]; then
  echo "session limit" > "\$D/out.log"
  echo 3 > "\$D/exit_code"
  exit 3
fi
echo "RESULT: ok" > "\$D/out.log"
echo 0 > "\$D/exit_code"
exit 0
EOF
chmod +x "$STUB"

PLAN="$TMP/plan.txt"
: > "$PLAN"
i=0
while [ $i -lt 6 ]; do
  TASK="$TMP/task-$i.md"
  echo "task $i" > "$TASK"
  echo "lane$i|$TASK|test -f f|haiku|none" >> "$PLAN"
  i=$((i+1))
done

CC_RUNS_DIR="$TMP/runs" CC_SWARMS_DIR="$TMP/swarms" CC_RUN_SH="$STUB" \
  CC_PG_CREDS="$TMP/no-creds" \
  CC_NOTIFY=/bin/true MAXPAR=1 \
  sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" limit-test
RC=$?

FAIL=0
if [ "$RC" != "3" ]; then
  echo "FAIL: очікував exit 3, отримав $RC"; FAIL=1
fi
for s in lane2 lane3 lane4 lane5; do
  if [ -e "$STARTED/$s" ]; then
    echo "FAIL: $s стартував після limit — не мав"; FAIL=1
  fi
done
[ -e "$STARTED/lane0" ] || { echo "FAIL: lane0 мав стартувати"; FAIL=1; }
[ -e "$STARTED/lane1" ] || { echo "FAIL: lane1 мав стартувати"; FAIL=1; }

MANIFEST="$TMP/swarms/limit-test/manifest.tsv"
if ! grep -qE '^lane0.*	ok	' "$MANIFEST" 2>/dev/null; then
  echo "FAIL: lane0 не позначено ok у маніфесті"; FAIL=1
fi
if ! grep -qE '^lane1.*	limit	' "$MANIFEST" 2>/dev/null; then
  echo "FAIL: lane1 не позначено limit у маніфесті"; FAIL=1
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: limit зупинив спавн lane2..lane5, exit 3"
