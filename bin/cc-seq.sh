#!/bin/sh
# Послідовний драйвер cc-ранів для НЕ-git робочої копії (cc-chain.sh вимагає git).
# Кожен рядок plan-файлу:  <run-dir>|<style>|<model>
# Стоп на першому не-0; окремо прокидає код 3 (session limit) і 5 (тижневий лок).
#   sh cc-seq.sh <plan-file> [tag]
#
# ENV: CC_RUNS (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs) — тека СТАНУ (лог-файл ланцюга)
set -u
BIN=$(dirname "$(readlink -f "$0")")
CC_RUNS=${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}
export CC_RUNS
PLAN=${1:?plan}; TAG=${2:-seq}
LOG="$CC_RUNS/$TAG-$(date +%Y%m%d-%H%M).log"
log(){ echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
notify(){ [ -f "$BIN/cc-notify.sh" ] || return 0; sh "$BIN/cc-notify.sh" "$*" >/dev/null 2>&1 || true; }
PASSED=0
log "seq старт: $PLAN"
while IFS='|' read -r d style model; do
  [ -n "${d:-}" ] || continue
  case "$d" in \#*) continue ;; esac
  log "$(basename "$d") старт (style=${style:-none} model=${model:-default})"
  CC_TAG="$TAG" sh "$BIN/cc-run.sh" "$d" "${style:-none}" "${model:-}" >> "$LOG" 2>&1
  RC=$?
  log "$(basename "$d") exit=$RC $(tail -1 "$d/usage.txt" 2>/dev/null)"
  if [ "$RC" != 0 ]; then
    log "СТОП на $(basename "$d") (exit $RC), пройдено $PASSED"
    notify "❌ $TAG · стоп на <code>$(basename "$d")</code> · exit $RC · $PASSED ok до цього"
    exit "$RC"
  fi
  PASSED=$((PASSED+1))
done < "$PLAN"
log "seq завершено, пройдено $PASSED"
notify "✅ $TAG · послідовність завершена · $PASSED ранів ok"
exit 0
