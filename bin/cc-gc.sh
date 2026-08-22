#!/bin/sh
# Ретеншен worktree/гілок рою (§9 SKILL.md). Знаходить `cc/*/*`-гілки й
# відповідні worktree старші за поріг (за датою останнього коміту в гілці).
# Лейн-гілки (`cc/<id>/<slug>`) і fanin-гілки (`cc/<id>/fanin`) прибираються
# незалежно від того, змержені лейн-гілки в fanin чи ні — fanin-гілка вже
# містить усе потрібне. Але жодна гілка, що ще НЕ увійшла в жодну fanin-гілку
# АБО в main, не видаляється — для неї лише попередження в консоль.
#
#   sh cc-gc.sh <repo> [--older-than-days N] [--dry-run]
#
# ENV: CC_SWARMS_DIR (дефолт /root/ops/cc-swarms) — тека worktree рою
#      CC_MAIN_BRANCH (дефолт main) — гілка, у яку рахується "змержено"
set -u

REPO=${1:?repo}; shift
DAYS=14
DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --older-than-days) DAYS=$2; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    *) echo "cc-gc: невідомий аргумент $1" >&2; exit 1 ;;
  esac
done

REPO_ABS=$(cd "$REPO" 2>/dev/null && pwd) || { echo "repo не існує: $REPO" >&2; exit 1; }
SWARMS=${CC_SWARMS_DIR:-/root/ops/cc-swarms}
MAIN=${CC_MAIN_BRANCH:-main}
NOW=$(date +%s)
THRESHOLD=$((DAYS * 86400))

git -C "$REPO_ABS" worktree prune

merged_into(){
  # 0 = так, змержено; 1 = ні
  BR=$1; TARGET=$2
  git -C "$REPO_ABS" show-ref --verify --quiet "refs/heads/$TARGET" || return 1
  git -C "$REPO_ABS" merge-base --is-ancestor "$BR" "$TARGET" 2>/dev/null
}

is_delivered(){
  # Лейн-гілка cc/<id>/<slug> вважається "доставленою", якщо змержена в
  # свою fanin-гілку cc/<id>/fanin АБО в main. Сама fanin-гілка — якщо
  # змержена в main.
  BR=$1
  case "$BR" in
    cc/*/fanin) merged_into "$BR" "$MAIN" && return 0; return 1 ;;
    cc/*/*)
      ID=$(echo "$BR" | cut -d/ -f2)
      merged_into "$BR" "cc/$ID/fanin" && return 0
      merged_into "$BR" "$MAIN" && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

remove_worktree_for(){
  BR=$1
  git -C "$REPO_ABS" worktree list --porcelain | awk -v b="refs/heads/$BR" '
    $1=="worktree"{wt=$2} $1=="branch" && $2==b{print wt}'
}

echo "cc-gc: repo=$REPO_ABS поріг=${DAYS}д dryrun=$DRYRUN main=$MAIN"

git -C "$REPO_ABS" for-each-ref --format='%(refname:short) %(committerdate:unix)' 'refs/heads/cc/*' |
while read -r BR TS; do
  [ -n "${BR:-}" ] || continue
  AGE=$((NOW - TS))
  [ "$AGE" -ge "$THRESHOLD" ] || continue

  if ! is_delivered "$BR"; then
    echo "cc-gc: ПОПЕРЕДЖЕННЯ — $BR старша за поріг, але не змержена в fanin/$MAIN — НЕ чіпаю"
    continue
  fi

  WT=$(remove_worktree_for "$BR")
  if [ "$DRYRUN" = "1" ]; then
    echo "cc-gc: [dry-run] видалив би $BR${WT:+ (worktree $WT)}"
    continue
  fi

  if [ -n "$WT" ]; then
    git -C "$REPO_ABS" worktree remove --force "$WT" \
      && echo "cc-gc: worktree видалено — $WT" \
      || echo "cc-gc: worktree remove впав для $WT" >&2
  fi
  git -C "$REPO_ABS" branch -D "$BR" \
    && echo "cc-gc: гілку видалено — $BR" \
    || echo "cc-gc: branch -D впав для $BR" >&2
done

echo "cc-gc: готово"
