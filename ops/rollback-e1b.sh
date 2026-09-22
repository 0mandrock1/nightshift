#!/bin/sh
# Відкат cutover-e1b.sh до стану «cc-swarm на e1b-canon, main=BASE, фізичні файли в cc-runs».
set -eu
BK=${1:?usage: rollback-e1b.sh <backup-dir>}
OLD=/root/projects/cc-swarm
NEW=/root/projects/nightshift
OPS=/root/ops/cc-runs
BASE=483a1a55c501cbf0098dd0c1e1f8a3a4223e9eb1
ARCH=/root/ops/_archive/launchers-20260922
[ -f "$BK/ts" ] || { echo "не бекап-тека: $BK" >&2; exit 1; }

for p in "$BK"/*.sh; do
  f=$(basename "$p")
  cp -a "$p" "$OPS/.$f.rb"
  mv -T "$OPS/.$f.rb" "$OPS/$f"
done
if [ -d "$NEW" ] && [ ! -L "$NEW" ]; then
  [ -L "$OLD" ] && rm "$OLD"
  rm -f "$NEW/bin/notify-swarm.env"
  mv "$NEW" "$OLD"
fi
git -C "$OLD" checkout -q e1b-canon
git -C "$OLD" update-ref refs/heads/main "$BASE"
[ -d "$ARCH" ] && for l in "$ARCH"/*.sh; do [ -e "$l" ] && mv "$l" "$OPS/"; done
echo "ROLLBACK OK"
