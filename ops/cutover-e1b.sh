#!/bin/sh
# E1b cutover: cc-swarm -> nightshift; CORE у /root/ops/cc-runs -> симлінки на nightshift/bin.
# Одноразовий. Відкат: rollback-e1b.sh <backup-dir> (шлях друкується останнім рядком).
set -eu
OLD=/root/projects/cc-swarm
NEW=/root/projects/nightshift
OPS=/root/ops/cc-runs
BASE=483a1a55c501cbf0098dd0c1e1f8a3a4223e9eb1
TS=$(date -u +%Y%m%d-%H%M%S)
BK=/root/ops/_archive/cutover-e1b-$TS
ARCH=/root/ops/_archive/launchers-20260922
CORE="cc-run cc-chain cc-seq cc-notify cc-opus-gate cc-cost cc-telemetry cc-week-guard cc-notify-swarm cc-swarm run-usage"
REPOINT="cc-estimate cc-lane-local cc-tg-format"
LAUNCHERS="bf6-after-bf5 cables-light-waiter debloat-series hydra-queue-worker inject-claude-md nightly-touchviz-launcher queue-autochange queue-recvpanel queue-tv-audio-real resume-tv-timeline-and-continue run-cables-gl-fix skills-cleanup-waiter tv-chain2-queued tv-deploy-prod tv-deploy-staging tv-desktop-fixes-waiter tv-final-launch tv-lp-waiter tv-mp-chain tv-night-chain tv-parity-rack-queue tv-perf-waiter tv-queue-fix-then-radial tv-round4-after3 tv-x-launch tv-x2-launch tv-x3-launch tv-x4-launch tv-x5-launch tv-x6-launch tv-x7-launch"

die(){ echo "CUTOVER ABORT: $*" >&2; exit 1; }
P='claude'' -p'

# 0. передумови — до першої мутації
pgrep -f "$P" >/dev/null && die "живий claude -p"
pgrep -f 'cc-(run|chain|seq|swarm)\.sh' >/dev/null && die "живий драйвер"
[ -d "$OLD/.git" ] && [ ! -L "$OLD" ] || die "$OLD не справжній репо"
[ ! -e "$NEW" ] || die "$NEW уже існує"
[ "$(git -C "$OLD" branch --show-current)" = e1b-canon ] || die "не на e1b-canon"
[ "$(git -C "$OLD" rev-parse main)" = "$BASE" ] || die "main зрушив"
git -C "$OLD" merge-base --is-ancestor main e1b-canon || die "e1b-canon не нащадок main"
[ -z "$(git -C "$OLD" status --porcelain)" ] || die "брудне дерево"
[ -L "$OLD/bin/notify.env" ] || die "нема bin/notify.env"
[ -f "$OPS/creds-swarm.env" ] || die "нема $OPS/creds-swarm.env"
for f in $CORE; do
  [ -e "$OPS/$f.sh" ] || die "нема $OPS/$f.sh"
  sh -n "$OLD/bin/$f.sh" || die "синтаксис bin/$f.sh"
done

# 1. бекап поточних шляхів (cp -a зберігає симлінки як симлінки)
mkdir -p "$BK"
for f in $CORE $REPOINT; do cp -a "$OPS/$f.sh" "$BK/"; done
echo "$TS" > "$BK/ts"
echo "$BK" > /tmp/e1b-bk

# 2. main := e1b-canon (update-ref зі звіркою старого значення, дерево не міняється)
git -C "$OLD" update-ref refs/heads/main "$(git -C "$OLD" rev-parse e1b-canon)" "$BASE"
git -C "$OLD" checkout -q main

# 3. тека + compat-симлінк старого шляху
mv "$OLD" "$NEW"
ln -s "$NEW" "$OLD"
ln -s "$OPS/creds-swarm.env" "$NEW/bin/notify-swarm.env"

# 4. атомарна підміна: новий inode через rename, живі sh тримають старий
for f in $CORE $REPOINT; do
  ln -s "$NEW/bin/$f.sh" "$OPS/.$f.sh.new"
  mv -T "$OPS/.$f.sh.new" "$OPS/$f.sh"
done

# 5. LAUNCHER-и в архів, тільки якщо ніде не згадані
mkdir -p "$ARCH"
for l in $LAUNCHERS; do
  [ -f "$OPS/$l.sh" ] || continue
  if crontab -l 2>/dev/null | grep -q "$l.sh" || grep -rqs "$l.sh" /etc/systemd/system /etc/cron.d; then
    echo "SKIP $l.sh — є referrer"; continue
  fi
  mv "$OPS/$l.sh" "$ARCH/"
done

# 6. статична звірка
for f in $CORE $REPOINT; do
  [ "$(readlink -f "$OPS/$f.sh")" = "$NEW/bin/$f.sh" ] || die "$f.sh резолвиться не туди — КЛИЧ ROLLBACK $BK"
done
echo "CUTOVER OK"
echo "$BK"
