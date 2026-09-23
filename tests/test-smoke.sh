#!/bin/sh
# Смоук: старі шляхи /root/ops/cc-runs/cc-swarm.sh і cc-lane-local.sh мають
# лишатись робочими симлінками на bin/* після перенесення продукту.
# DRYRUN=1 — валідація/worktree/маніфест без реального спавну (claude -p не викликається).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OLD_SWARM=/root/ops/cc-runs/cc-swarm.sh
OLD_LOCAL=/root/ops/cc-runs/cc-lane-local.sh

FAIL=0
for f in "$OLD_SWARM" "$OLD_LOCAL"; do
  if [ ! -L "$f" ]; then echo "FAIL: $f не симлінк"; FAIL=1; fi
  if [ ! -x "$f" ]; then echo "FAIL: $f не виконуваний (через симлінк)"; FAIL=1; fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm init

PLAN="$TMP/plan.txt"
i=0
: > "$PLAN"
while [ $i -lt 3 ]; do
  TASK="$TMP/task-$i.md"
  echo "task $i" > "$TASK"
  echo "lane$i|$TASK|grep -q X f|haiku|none" >> "$PLAN"
  i=$((i+1))
done

CC_RUNS_DIR="$TMP/runs" CC_SWARMS_DIR="$TMP/swarms" CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
  CC_PG_CREDS="$TMP/no-creds" \
  DRYRUN=1 sh "$OLD_SWARM" "$REPO" "$PLAN" smoke-test
RC=$?
if [ "$RC" != "0" ]; then echo "FAIL: DRYRUN мав завершитись 0, отримав $RC"; FAIL=1; fi

MANIFEST="$TMP/swarms/smoke-test/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "FAIL: нема маніфесту $MANIFEST"; FAIL=1; }
N=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
[ "$N" = "3" ] || { echo "FAIL: очікував 3 рядки маніфесту, є $N"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: старі шляхи — робочі симлінки, DRYRUN пройшов валідацію/маніфест на 3 лейнах"
