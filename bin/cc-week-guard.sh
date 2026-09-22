#!/bin/sh
# Тижневий вартовий (крон): читає офіційний util7d і керує локом .week-locked,
# який поважають cc-chain/cc-run/cc-swarm. < порогу -> лок (рани на вузлі глушаться);
# >= порогу (тиждень скинувся) -> лок знято. Idempotent, self-healing.
# Нотифікація ТІЛЬКИ на переході lock<->unlock, не щотіка.
# DRYRUN=1 -> лише друкує намір, файл/нотифікацію не чіпає.
# Fail-open: число недоступне -> нічого не робить (не локає на порожнечі).
#
# ENV: CC_RUNS (дефолт $HOME/ops/cc-runs) — тека СТАНУ (.week-locked)
set -u
export PATH=/usr/local/bin:/usr/bin:/bin
BIN=$(dirname "$(readlink -f "$0")")
CC_RUNS=${CC_RUNS:-$HOME/ops/cc-runs}
export CC_RUNS
LOCK="$CC_RUNS/.week-locked"
THRESH=${CC_WEEK_MIN_LEFT:-5}
DRYRUN=${DRYRUN:-0}
USAGE_CLI=${CC_USAGE_CLI:-/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js}
notify(){ [ "$DRYRUN" = 1 ] && { echo "[dry] notify: $*"; return; }; sh "$BIN/cc-notify.sh" "$*" >/dev/null 2>&1 || true; }

U7=$(cd "$(dirname "$USAGE_CLI")" 2>/dev/null; node "$USAGE_CLI" --ratelimit-json 2>/dev/null | jq -r '.util7d // empty' 2>/dev/null)
case "$U7" in ''|*[!0-9.]*) exit 0 ;; esac
LEFT=$(awk -v u="$U7" 'BEGIN{printf "%.1f",(1-u)*100}')
BELOW=$(awk -v l="$LEFT" -v m="$THRESH" 'BEGIN{print (l<m)?1:0}')

if [ "$BELOW" = 1 ]; then
  if [ ! -f "$LOCK" ]; then
    if [ "$DRYRUN" = 1 ]; then echo "[dry] LOCK: тижня ${LEFT}% < ${THRESH}% -> створив би $LOCK"
    else printf 'locked %s util7d=%s left=%s%%\n' "$(date -u +%FT%TZ)" "$U7" "$LEFT" > "$LOCK"; fi
    notify "🚧 тиждень · лишилось ${LEFT}% < ${THRESH}% · cc-рани на вузлі заглушено до скидання"
  fi
else
  if [ -f "$LOCK" ]; then
    if [ "$DRYRUN" = 1 ]; then echo "[dry] UNLOCK: тижня ${LEFT}% >= ${THRESH}% -> зняв би $LOCK"
    else rm -f "$LOCK"; fi
    notify "✅ тиждень · лишилось ${LEFT}% · лок знято, cc-рани на вузлі розблоковано"
  fi
fi
[ "$DRYRUN" = 1 ] && echo "[dry] util7d=$U7 left=${LEFT}% thresh=${THRESH}% below=$BELOW lock=$([ -f "$LOCK" ] && echo yes || echo no)"
exit 0
