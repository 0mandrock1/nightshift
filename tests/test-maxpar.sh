#!/bin/sh
# Доводить, що MAXPAR реально стримує паралельність (регрес: `wait -n` на dash
# фолбечив на `wait $first_pid`, який уже пожатий -> стеля не працювала).
# 6 лейнів, MAXPAR=2, кожен пише start/end timestamp у власний файл; перевірка,
# що ніколи не було >2 живих лейнів одночасно.
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

MARKS="$TMP/marks"
mkdir -p "$MARKS"

STUB="$TMP/stub-run.sh"
cat > "$STUB" <<EOF
#!/bin/sh
D=\$1
SLUG=\$(basename "\$D")
SLUG=\${SLUG#maxpar-test-}
echo "start \$(date +%s.%N)" >> "$MARKS/\$SLUG"
sleep 1
echo "end \$(date +%s.%N)" >> "$MARKS/\$SLUG"
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
  CC_NOTIFY=/bin/true MAXPAR=2 \
  sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" maxpar-test
RC=$?

if [ "$RC" != "0" ]; then
  echo "FAIL: очікував exit 0, отримав $RC"
  exit 1
fi

# Перевірка перекриття інтервалів: скласти всі (start,end) і рахнути макс. одночасність
python3 - "$MARKS" <<'PYEOF'
import sys, glob, os
marks_dir = sys.argv[1]
events = []
for f in glob.glob(os.path.join(marks_dir, "*")):
    lines = open(f).read().splitlines()
    start = end = None
    for l in lines:
        k, v = l.split()
        if k == "start": start = float(v)
        if k == "end": end = float(v)
    if start is None or end is None:
        print(f"FAIL: {f} не має start/end")
        sys.exit(1)
    events.append((start, 1))
    events.append((end, -1))
events.sort()
cur = mx = 0
for _, d in events:
    cur += d
    mx = max(mx, cur)
if mx > 2:
    print(f"FAIL: максимальна одночасність {mx} > MAXPAR=2")
    sys.exit(1)
print(f"OK: максимальна одночасність {mx} <= 2, лейнів оброблено {len(events)//2}")
PYEOF
