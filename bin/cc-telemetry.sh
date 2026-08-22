#!/bin/sh
# UPSERT одного рядка swarm.runs з даних тек рану. Best-effort: будь-яка помилка
# (нема креденшлів, контейнер лежить, jq/docker відсутні) пишеться в лог і
# завершується exit 0 — ран, який це викликав, ніколи не падає через телеметрію.
#
#   sh cc-telemetry.sh <run-dir> <kind> [parent-run-id]
#     kind: run|chain|swarm|lane|fanin
#   sh cc-telemetry.sh verification <run-dir> <verify-cmd> <exit-code> <duration-s>
#     INSERT в swarm.verifications (run_id = basename run-dir), той самий
#     best-effort контракт — ніколи не валить викликача.
set -u

if [ "${1:-}" = "verification" ]; then
  shift
  D=${1:?run-dir}; D=${D%/}
  VCMD=${2:-}
  VEXIT=${3:-}
  VDUR=${4:-0}

  CREDS=${CC_PG_CREDS:-/root/ops/cc-runs/creds-pg.env}
  LOG=${CC_TELEMETRY_LOG:-/root/ops/cc-runs/telemetry.log}
  PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
  PG_DB=${CC_PG_DB:-mandrock_kb}
  PG_USER=${CC_PG_USER:-mandrock}
  PG_HOST=${CC_PG_HOST:-127.0.0.1}
  PG_PORT=${CC_PG_PORT:-5432}

  log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }
  soft(){ log "cc-telemetry(verification): $* — пропущено"; exit 0; }

  [ -f "$CREDS" ] || soft "нема креденшлів $CREDS"
  command -v docker >/dev/null 2>&1 || soft "нема docker"
  PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${PGPASSWORD:-}" ] || soft "порожній POSTGRES_PASSWORD у $CREDS"

  esc(){ printf '%s' "$1" | sed "s/'/''/g"; }
  RUN_ID=$(basename "$D")
  case "${VEXIT:-}" in ''|*[!0-9]*) VEXIT_SQL="NULL" ;; *) VEXIT_SQL=$VEXIT ;; esac
  case "${VDUR:-}" in ''|*[!0-9]*) VDUR_SQL="NULL" ;; *) VDUR_SQL=$VDUR ;; esac

  SQL="INSERT INTO swarm.verifications (run_id, verify_cmd, exit_code, duration_s) VALUES ('$(esc "$RUN_ID")', '$(esc "$VCMD")', $VEXIT_SQL, $VDUR_SQL);"
  echo "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q \
    > "$LOG.last-verification" 2>&1
  RC=$?
  if [ "$RC" != "0" ]; then
    log "verification INSERT впав для $RUN_ID (rc=$RC): $(tail -3 "$LOG.last-verification" | tr '\n' ' ')"
    exit 0
  fi
  log "verification ok: $RUN_ID exit=$VEXIT dur=${VDUR}s"
  exit 0
fi

D=${1:?run-dir}; D=${D%/}
KIND=${2:?kind}
PARENT=${3:-}

CREDS=${CC_PG_CREDS:-/root/ops/cc-runs/creds-pg.env}
LOG=${CC_TELEMETRY_LOG:-/root/ops/cc-runs/telemetry.log}
PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
PG_DB=${CC_PG_DB:-mandrock_kb}
PG_USER=${CC_PG_USER:-mandrock}
PG_HOST=${CC_PG_HOST:-127.0.0.1}
PG_PORT=${CC_PG_PORT:-5432}

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }
soft(){ log "cc-telemetry: $* — пропущено, ран не зачеплено"; exit 0; }

[ -f "$D/task.md" ] || soft "нема $D/task.md"
[ -f "$CREDS" ] || soft "нема креденшлів $CREDS"
command -v jq >/dev/null 2>&1 || soft "нема jq"
command -v docker >/dev/null 2>&1 || soft "нема docker"

PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
[ -n "${PGPASSWORD:-}" ] || soft "порожній POSTGRES_PASSWORD у $CREDS"

esc(){ printf '%s' "$1" | sed "s/'/''/g"; }

RUN_ID=$(basename "$D")
STARTED=$(stat -c %Y "$D/task.md" 2>/dev/null || echo 0)
FINISHED=$([ -f "$D/out.log" ] && stat -c %Y "$D/out.log" 2>/dev/null || echo "$STARTED")
DURATION=$((FINISHED - STARTED))
[ "$DURATION" -ge 0 ] || DURATION=0

EXIT_CODE=$(cat "$D/exit_code" 2>/dev/null || true)
case "${EXIT_CODE:-}" in
  0) STATUS=ok ;;
  3) STATUS=limit ;;
  124) STATUS=timeout ;;
  *) STATUS=fail ;;
esac
EXIT_CODE_SQL="NULL"
case "${EXIT_CODE:-}" in ''|*[!0-9]*) : ;; *) EXIT_CODE_SQL=$EXIT_CODE ;; esac

TOKENS_IN=0; TOKENS_OUT=0; CACHE_R=0; CACHE_W=0; MODEL="unknown"
if [ -f "$D/usage.json" ]; then
  TOKENS_IN=$(jq -r '.total_in // 0' "$D/usage.json" 2>/dev/null || echo 0)
  TOKENS_OUT=$(jq -r '.total_out // 0' "$D/usage.json" 2>/dev/null || echo 0)
  CACHE_R=$(jq -r '[.models[].cache_r] | add // 0' "$D/usage.json" 2>/dev/null || echo 0)
  CACHE_W=$(jq -r '[.models[].cache_w] | add // 0' "$D/usage.json" 2>/dev/null || echo 0)
  MODEL_RAW=$(jq -r '[.models[].model] | sort_by(-length) | .[0] // "unknown"' "$D/usage.json" 2>/dev/null || echo unknown)
fi
[ -n "${MODEL_RAW:-}" ] || MODEL_RAW="unknown"
# Нормалізація до tier-шорткату (sonnet/opus/haiku) — саме так cc-estimate.sh
# запитує медіану (--model sonnet), а usage.json тримає повний ідентифікатор
# моделі (claude-sonnet-5 тощо); без нормалізації медіана ніколи б не матчилась.
case "$MODEL_RAW" in
  *sonnet*) MODEL=sonnet ;;
  *opus*)   MODEL=opus ;;
  *haiku*)  MODEL=haiku ;;
  *)        MODEL=$MODEL_RAW ;;
esac

NOTES=$(tail -40 "$D/out.log" 2>/dev/null | grep -aE "^[[:space:]]*\**[[:space:]]*NOTES:" | tail -1 | cut -c1-500)

NODE=$(hostname -f 2>/dev/null || hostname)
PARENT_SQL="NULL"
[ -n "$PARENT" ] && PARENT_SQL="'$(esc "$PARENT")'"

SQL="INSERT INTO swarm.runs
  (run_id, kind, parent_run_id, node, model, started_at, finished_at, duration_s, exit_code, status, tokens_in, tokens_out, cache_read, cache_write, notes)
VALUES
  ('$(esc "$RUN_ID")', '$(esc "$KIND")', $PARENT_SQL, '$(esc "$NODE")', '$(esc "$MODEL")',
   to_timestamp($STARTED), to_timestamp($FINISHED), $DURATION, $EXIT_CODE_SQL, '$(esc "$STATUS")',
   $TOKENS_IN, $TOKENS_OUT, $CACHE_R, $CACHE_W, '$(esc "$NOTES")')
ON CONFLICT (run_id) DO UPDATE SET
  finished_at = EXCLUDED.finished_at,
  duration_s  = EXCLUDED.duration_s,
  exit_code   = EXCLUDED.exit_code,
  status      = EXCLUDED.status,
  tokens_in   = EXCLUDED.tokens_in,
  tokens_out  = EXCLUDED.tokens_out,
  cache_read  = EXCLUDED.cache_read,
  cache_write = EXCLUDED.cache_write,
  notes       = EXCLUDED.notes;

UPDATE swarm.estimates SET actual_tokens = $((TOKENS_IN + TOKENS_OUT)), actual_minutes = ROUND(($DURATION / 60.0)::numeric, 2)
  WHERE run_id = '$(esc "$RUN_ID")';"

echo "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
  psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q \
  > "$LOG.last" 2>&1
RC=$?
if [ "$RC" != "0" ]; then
  log "UPSERT впав для $RUN_ID (rc=$RC): $(tail -3 "$LOG.last" | tr '\n' ' ')"
  exit 0
fi
log "UPSERT ok: $RUN_ID kind=$KIND status=$STATUS tokens_in=$TOKENS_IN tokens_out=$TOKENS_OUT"
exit 0
