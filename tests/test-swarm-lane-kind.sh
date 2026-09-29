#!/bin/sh
# Лейни рою мають писати task_kind = слаг лейна (CC_KIND="$slug"), не kind
# кампанії (SWARM_ID) — інакше калібрування model×kind у cc-estimate.sh v2
# групує всі лейни рою під одним kind замість типу конкретної задачі.
# Кейси:
#   (a) статична: рядок спавну лейна в bin/cc-swarm.sh містить CC_KIND="$slug"
#       у тому ж env-префіксі, що й CC_TELEMETRY_KIND=lane (греп-контракт,
#       щоб регрес не повернувся тихо)
#   (b) функціональна: cc_task_kind() з cc-util-lib.sh реально бере CC_KIND,
#       якщо він заданий, інакше фолбек на префікс id
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
FAIL=0

# --- (a) статична перевірка bin/cc-swarm.sh ---
LINE=$(grep -n 'CC_TELEMETRY_KIND=lane' "$BIN/cc-swarm.sh")
if [ -z "$LINE" ]; then
  echo "FAIL(a): не знайшов рядок CC_TELEMETRY_KIND=lane у bin/cc-swarm.sh — контракт тесту протух"
  FAIL=1
else
  echo "$LINE" | grep -q 'CC_KIND="\$slug"' \
    || { echo "FAIL(a): рядок спавну лейна без CC_KIND=\"\$slug\": $LINE"; FAIL=1; }
fi

# --- (b) функціональна перевірка cc_task_kind() ---
OUT_WITH=$(CC_KIND=tv sh -c ". \"$BIN/cc-util-lib.sh\"; cc_task_kind ssot-x-20260929-tv")
[ "$OUT_WITH" = "tv" ] || { echo "FAIL(b1): очікував tv, отримав: $OUT_WITH"; FAIL=1; }

OUT_WITHOUT=$(sh -c ". \"$BIN/cc-util-lib.sh\"; cc_task_kind ssot-x-20260929-tv")
[ "$OUT_WITHOUT" = "ssot" ] || { echo "FAIL(b2): очікував ssot, отримав: $OUT_WITHOUT"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: спавн лейна пише CC_KIND=\"\$slug\" (a), cc_task_kind() поважає CC_KIND (b)"
