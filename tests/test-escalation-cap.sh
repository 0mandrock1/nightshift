#!/bin/sh
# Доводить: друга ескалація (attempt попереднього рою >=2) відмовляється до
# спавну; БД недоступна -> теж відмова (fail-closed, §6 SKILL.md / Блокер 6).
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

TASK="$TMP/task.md"; echo "task" > "$TASK"
PLAN="$TMP/plan.txt"
echo "lane0|$TASK|grep -q X f|haiku|none" > "$PLAN"

FAIL=0

# --- 1. Без БД (нема CC_PG_CREDS) + ESCALATION_OF заданий -> fail-closed ---
STARTED1="$TMP/started1"; mkdir -p "$STARTED1"
CC_RUNS_DIR="$TMP/runs1" CC_SWARMS_DIR="$TMP/swarms1" CC_NOTIFY=/bin/true \
  CC_PG_CREDS="$TMP/no-creds" \
  ESCALATION_OF="prev-run-id" \
  DRYRUN=1 sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" "esc-nodb" >"$TMP/out1.log" 2>&1
RC1=$?
if [ "$RC1" = "1" ]; then
  echo "OK: без БД + ESCALATION_OF -> відмова (exit 1, fail-closed)"
else
  echo "FAIL: без БД мав відмовити (exit 1), отримав $RC1"; FAIL=1
fi
[ -d "$TMP/swarms1/esc-nodb" ] && { echo "FAIL: swarm-тека створена попри fail-closed відмову"; FAIL=1; }

# --- 2. Стаб docker/psql, що каже attempt=2 для попереднього рану -> відмова ---
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/sh
# Стаб: будь-який `docker exec ... psql ... -tAc "SELECT attempt ..."` -> "2"
echo "2"
EOF
chmod +x "$FAKEBIN/docker"
echo "POSTGRES_PASSWORD=fake" > "$TMP/fake-creds.env"

STARTED2="$TMP/started2"; mkdir -p "$STARTED2"
PATH="$FAKEBIN:$PATH" \
  CC_RUNS_DIR="$TMP/runs2" CC_SWARMS_DIR="$TMP/swarms2" CC_NOTIFY=/bin/true \
  CC_PG_CREDS="$TMP/fake-creds.env" \
  ESCALATION_OF="prev-run-id" \
  DRYRUN=1 sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" "esc-cap" >"$TMP/out2.log" 2>&1
RC2=$?
if [ "$RC2" = "1" ]; then
  echo "OK: attempt=2 попереднього рану -> відмова (exit 1, стеля вичерпана)"
else
  echo "FAIL: attempt=2 мав відмовити (exit 1), отримав $RC2"; FAIL=1
fi
[ -d "$TMP/swarms2/esc-cap" ] && { echo "FAIL: swarm-тека створена попри стелю ескалацій"; FAIL=1; }

# --- 3. Стаб, що каже attempt=1 -> дозволено (перша ескалація) ---
cat > "$FAKEBIN/docker" <<'EOF'
#!/bin/sh
echo "1"
EOF
chmod +x "$FAKEBIN/docker"
PATH="$FAKEBIN:$PATH" \
  CC_RUNS_DIR="$TMP/runs3" CC_SWARMS_DIR="$TMP/swarms3" CC_NOTIFY=/bin/true \
  CC_PG_CREDS="$TMP/fake-creds.env" \
  ESCALATION_OF="prev-run-id" \
  DRYRUN=1 sh "$BIN/cc-swarm.sh" "$REPO" "$PLAN" "esc-ok" >"$TMP/out3.log" 2>&1
RC3=$?
if [ "$RC3" = "0" ]; then
  echo "OK: attempt=1 попереднього рану -> перша ескалація дозволена (exit 0)"
else
  echo "FAIL: attempt=1 мав дозволити (exit 0), отримав $RC3"; FAIL=1
  cat "$TMP/out3.log"
fi

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: стеля ескалацій — друга відмовляється, БД недоступна теж відмовляється"
