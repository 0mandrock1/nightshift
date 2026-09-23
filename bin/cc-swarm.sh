#!/bin/sh
# Драйвер РОЮ: N незалежних cc-run.sh у власних worktree, fan-in на fanin-гілку.
# Не реалізує спавн заново — оркеструє виклики cc-run.sh (той самий бінарник,
# що й для одиночних ранів): worktree-ізоляція, стеля паралельності, машинний
# verify-cmd, fan-in, маніфест. Конвенції логів/локів — як у cc-chain.sh.
#
#   sh cc-swarm.sh <repo> <swarm-plan> <swarm-id>
#
# Формат plan-файлу (| -розділений, по рядку на лейн):
#   lane-slug|task.md|verify-cmd|model|style|backend
#     model  дефолт haiku (claude) / gpt-6-luna (codex); local:<tag> -> лейн
#            іде в cc-lane-local.sh (тільки claude-шлях, backend не читається)
#     style  дефолт none
#     backend (6-те поле, опційно): claude|codex — перекриває CC_BACKEND для
#            цього лейна; порожньо -> CC_BACKEND -> claude. Прокидається як
#            4-й аргумент у cc-run.sh (той самий біжучий раннер, що й для
#            одиночних ранів) — увесь codex-мапінг моделі/сесія-ліміту/
#            RESULT-парсингу вже реалізовано там, тут лише передається.
#     verify-cmd ОБОВ'ЯЗКОВИЙ — виконується В worktree лейна, exit 0 = ok
# Fan-in (опційно): якщо існує <swarm-plan>.fanin — це task.md для зведення,
#   виконується після лейнів на гілці cc/<swarm-id>/fanin, model=sonnet,
#   backend=CC_BACKEND (немає власного поля — фан-ін один на весь рій).
#
# ENV: MAXPAR (дефолт 4) — стеля паралельних лейнів, застосовується реально
#        (pid-список у файлі + kill -0 полінг, POSIX-сумісно, без `wait -n`)
#      LANE_TIMEOUT (дефолт 1800с) — таймаут одного лейна (coreutils `timeout`);
#        лейн, що вийшов по таймауту, отримує статус `timeout` у маніфесті і
#        НЕ блокує решту рою
#      DRYRUN=1 — уся валідація/worktree/маніфест виконуються, лейни НЕ спавняться
#      CC_BACKEND (дефолт claude) — claude|codex для лейнів без власного 6-го
#        поля плану; codex-лейни за замовчуванням ідуть на gpt-6-luna
#        (мапінг дефолтної моделі — в самому cc-run.sh)
#      CC_TOOLS, CC_NOTIFY (успадковується cc-run.sh; тут дефолт cc-notify-swarm.sh)
#      CC_RUNS (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs) — тека СТАНУ (run-dirs, локи, логи);
#        CC_RUNS_DIR лишено як алiас для зворотної сумісності й ЯВНО перевизначає
#        CC_RUNS для цього процесу (і дочірніх, куди він далі експортується)
#      CC_SWARMS_DIR (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-swarms) — тека worktree/маніфестів
#      CC_RUN_SH (дефолт <bin>/cc-run.sh) — біжучий раннер (перевизначається в тестах)
#      CC_LANE_LOCAL_SH (дефолт <bin>/cc-lane-local.sh) — раннер local:* лейнів
#
# Коди виходу: 0 усі ok (+fan-in ok) | 1 невалідний план | 2 є фейли | 3 session limit (claude чи codex-квота) | 5 тижневий лок
set -u
BIN=$(dirname "$(readlink -f "$0")")
# NODE: CC_RUNS_DIR — старіша назва змінної цього скрипта, лишена як алiас;
# дефолт-ланцюжок резолвиться через CC_RUNS ($(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs), не хардкод.
CC_RUNS=${CC_RUNS_DIR:-${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}}
export CC_RUNS

# --- Тижневий лок (крон cc-week-guard.sh) ---
# Присутній .week-locked -> тижневого бюджету менше порогу, cc-рани на вузлі
# заглушено до скидання тижня. Дешева перевірка (без node/jq); знімає лок крон.
WEEK_LOCK=${CC_WEEK_LOCK:-$CC_RUNS/.week-locked}
if [ -f "$WEEK_LOCK" ]; then
  echo "ВІДМОВА: тижневий лок активний ($WEEK_LOCK) — cc-рани заглушено до скидання тижня" >&2
  exit 5
fi

REPO=${1:?repo}; PLAN=${2:?swarm-plan}; SWARM_ID=${3:?swarm-id}
ESCALATION_OF=${ESCALATION_OF:-}
ATTEMPT=1
RUNS=$CC_RUNS
SWARMS=${CC_SWARMS_DIR:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-swarms}
MAXPAR=${MAXPAR:-4}
LANE_TIMEOUT=${LANE_TIMEOUT:-1800}
DRYRUN=${DRYRUN:-0}
export CC_NOTIFY=${CC_NOTIFY:-$BIN/cc-notify-swarm.sh}
export CC_TAG=${CC_TAG:-swarm}
CC_RUN_SH=${CC_RUN_SH:-$BIN/cc-run.sh}
CC_LANE_LOCAL_SH=${CC_LANE_LOCAL_SH:-$BIN/cc-lane-local.sh}
CC_BACKEND=${CC_BACKEND:-claude}

REPO_ABS=$(cd "$REPO" 2>/dev/null && pwd) || { echo "repo не існує: $REPO" >&2; exit 1; }
PLAN_ABS=$(readlink -f "$PLAN" 2>/dev/null) || { echo "план не існує: $PLAN" >&2; exit 1; }
SWARM_DIR="$SWARMS/$SWARM_ID"

notify(){ sh "$CC_NOTIFY" "$*" >/dev/null 2>&1 || true; }
die(){ echo "cc-swarm: $*" >&2; notify "swarm $SWARM_ID: ВІДМОВА — $*"; exit 1; }

# Агрегатний рядок swarm.runs (kind=swarm) — best-effort, суми токенів з лейнів,
# уже записаних дочірньою телеметрією cc-run.sh. Ніколи не валить рій.
telemetry_self(){
  STATUS_ARG=$1
  CREDS=${CC_PG_CREDS:-$RUNS/creds-pg.env}
  [ -f "$CREDS" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${PGPASSWORD:-}" ] || return 0
  PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
  PG_DB=${CC_PG_DB:-mandrock_kb}
  PG_USER=${CC_PG_USER:-mandrock}
  NODE=$(hostname -f 2>/dev/null || hostname)
  esc(){ printf '%s' "$1" | sed "s/'/''/g"; }
  ESC_OF_SQL="NULL"
  [ -n "$ESCALATION_OF" ] && ESC_OF_SQL="'$(esc "$ESCALATION_OF")'"
  SQL="INSERT INTO swarm.runs (run_id, kind, node, repo, base_sha, started_at, finished_at, status, tokens_in, tokens_out, escalation_of, attempt)
    VALUES ('$(esc "$SWARM_ID")', 'swarm', '$(esc "$NODE")', '$(esc "$REPO_ABS")', '$(esc "$BASE_SHA")',
      coalesce((SELECT min(started_at) FROM swarm.runs WHERE parent_run_id='$(esc "$SWARM_ID")'), now()), now(), '$(esc "$STATUS_ARG")',
      coalesce((SELECT sum(tokens_in) FROM swarm.runs WHERE parent_run_id='$(esc "$SWARM_ID")'),0),
      coalesce((SELECT sum(tokens_out) FROM swarm.runs WHERE parent_run_id='$(esc "$SWARM_ID")'),0),
      $ESC_OF_SQL, $ATTEMPT)
    ON CONFLICT (run_id) DO UPDATE SET finished_at=EXCLUDED.finished_at, status=EXCLUDED.status, tokens_in=EXCLUDED.tokens_in, tokens_out=EXCLUDED.tokens_out;"
  echo "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    psql -h "${CC_PG_HOST:-127.0.0.1}" -p "${CC_PG_PORT:-5432}" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 || true
}

# --- Стеля ескалацій (§6 SKILL.md): переживає рестарт через swarm.runs.attempt.
# ESCALATION_OF=<run_id> попереднього рою -> attempt(попередній)>=2 -> відмова
# ще до будь-якого спавну. Без БД перевірку зробити неможливо -> fail-closed
# (відмова, не мовчазний дозвіл) — це єдине місце, де відсутність БД блокує ран.
check_escalation(){
  [ -n "$ESCALATION_OF" ] || return 0
  CREDS=${CC_PG_CREDS:-$RUNS/creds-pg.env}
  PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
  PG_DB=${CC_PG_DB:-mandrock_kb}
  PG_USER=${CC_PG_USER:-mandrock}
  PG_HOST=${CC_PG_HOST:-127.0.0.1}
  PG_PORT=${CC_PG_PORT:-5432}
  [ -f "$CREDS" ] || die "ескалація $ESCALATION_OF: БД недоступна (нема $CREDS) — fail-closed, стелю ескалацій неможливо перевірити"
  command -v docker >/dev/null 2>&1 || die "ескалація $ESCALATION_OF: БД недоступна (нема docker) — fail-closed"
  ESC_PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${ESC_PGPASSWORD:-}" ] || die "ескалація $ESCALATION_OF: БД недоступна (порожній POSTGRES_PASSWORD) — fail-closed"
  PREV=$(docker exec -e PGPASSWORD="$ESC_PGPASSWORD" "$PG_CONTAINER" \
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tAc \
    "SELECT attempt FROM swarm.runs WHERE run_id='$(printf '%s' "$ESCALATION_OF" | sed "s/'/''/g")';" 2>/dev/null)
  case "${PREV:-}" in '' ) die "ескалація $ESCALATION_OF: попередній ран не знайдено в swarm.runs — fail-closed" ;; esac
  case "$PREV" in *[!0-9]*) die "ескалація $ESCALATION_OF: attempt не число ('$PREV') — fail-closed" ;; esac
  [ "$PREV" -lt 2 ] || die "стеля ескалацій вичерпана (attempt=$PREV) — віддай задачу одним звичайним раном"
  ATTEMPT=$((PREV + 1))
}
check_escalation

# --- FACT-блок (best-effort): бере actual з swarm.runs (щойно записаного
# telemetry_self) і predicted з swarm.estimates (записаного cc-estimate.sh
# на старті), рендерить через cc-tg-format.sh. Порожній рядок -> викликач
# падає назад на старий однорядковий текст.
fact_block(){
  CC_TG_FORMAT_SH=${CC_TG_FORMAT_SH:-$BIN/cc-tg-format.sh}
  [ -x "$CC_TG_FORMAT_SH" ] || return 0
  CREDS=${CC_PG_CREDS:-$RUNS/creds-pg.env}
  [ -f "$CREDS" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  FPGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -n "${FPGPASSWORD:-}" ] || return 0
  ROW=$(docker exec -e PGPASSWORD="$FPGPASSWORD" "${CC_PG_CONTAINER:-mandrock-kb-postgres}" \
    psql -h "${CC_PG_HOST:-127.0.0.1}" -p "${CC_PG_PORT:-5432}" -U "${CC_PG_USER:-mandrock}" -d "${CC_PG_DB:-mandrock_kb}" -tAc \
    "SELECT r.tokens_in+r.tokens_out, round(r.duration_s/60.0,1), coalesce(e.predicted_tokens,0), coalesce(e.predicted_minutes,0)
     FROM swarm.runs r LEFT JOIN swarm.estimates e ON e.run_id=r.run_id
     WHERE r.run_id='$(printf '%s' "$SWARM_ID" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null)
  [ -n "$ROW" ] || return 0
  F_ATOK=$(echo "$ROW" | cut -d'|' -f1 | tr -d '[:space:]')
  F_AMIN=$(echo "$ROW" | cut -d'|' -f2 | tr -d '[:space:]')
  F_PTOK=$(echo "$ROW" | cut -d'|' -f3 | tr -d '[:space:]')
  F_PMIN=$(echo "$ROW" | cut -d'|' -f4 | tr -d '[:space:]')
  [ -n "${F_ATOK:-}" ] || return 0
  sh "$CC_TG_FORMAT_SH" fact --id "$SWARM_ID" --ok "$1" --total "$2" \
    --actual-tokens "$F_ATOK" --predicted-tokens "${F_PTOK:-0}" \
    --actual-minutes "${F_AMIN:-0}" --predicted-minutes "${F_PMIN:-0}" \
    --basis-runs "${V_BASISN:-0}" --basis-err "${V_BASISERR:-}" 2>/dev/null
}

# --- Лок на swarm-id (mkdir, атомарний; той самий підхід, що й у cc-chain.sh) ---
mkdir -p "$RUNS"
LOCK="$RUNS/.lock-swarm-$SWARM_ID.d"
mkdir "$LOCK" 2>/dev/null || die "інший рій вже працює під id $SWARM_ID (lock $LOCK)"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- 1. Валідація плану ДО спавну ---
[ -s "$PLAN_ABS" ] || die "план порожній: $PLAN_ABS"

SLUGS=""
LANE_N=0
while IFS='|' read -r slug task verify model style backend_raw; do
  [ -n "${slug:-}" ] || continue
  case "$slug" in \#*) continue ;; esac
  LANE_N=$((LANE_N+1))
  case " $SLUGS " in *" $slug "*) die "дубльований slug: $slug" ;; esac
  SLUGS="$SLUGS $slug"
  [ -f "$task" ] || die "лейн $slug: нема task-файлу $task"
  [ -n "${verify:-}" ] || die "лейн $slug: verify-cmd порожній (заборонено)"
  BACKEND_CHECK=${backend_raw:-$CC_BACKEND}
  case "$BACKEND_CHECK" in
    claude|codex) : ;;
    *) die "лейн $slug: невідомий backend '$BACKEND_CHECK' (очікую claude|codex)" ;;
  esac
  VTRIM=$(printf '%s' "$verify" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$VTRIM" in
    true|:|"exit 0"|"echo ok") die "лейн $slug: verify-cmd '$VTRIM' — точний збіг з фіктивною командою (денилист §8 SKILL.md), не машинний гейт" ;;
  esac
  case "$VTRIM" in
    echo\ *)
      case "$VTRIM" in *"&&"*|*";"*|*"|"*) : ;; *) die "лейн $slug: verify-cmd '$VTRIM' — голий echo без &&/;/| іншої команди, не гейт" ;; esac
      ;;
  esac
done < "$PLAN_ABS"
[ "$LANE_N" -gt 0 ] || die "план не містить жодного валідного лейна"

# --- Повторний запуск: прибрати мертві worktree-записи і не топтати живу теку ---
git -C "$REPO_ABS" worktree prune
if [ -d "$SWARM_DIR" ]; then
  for slug in $SLUGS; do
    [ -e "$SWARM_DIR/$slug" ] && die "тека лейна вже зайнята з попереднього рою: $SWARM_DIR/$slug (прибери її або обери інший swarm-id)"
  done
fi

# --- base-sha фіксується один раз для всіх лейнів ---
BASE_SHA=$(git -C "$REPO_ABS" rev-parse HEAD) || die "не можу визначити HEAD у $REPO_ABS"

mkdir -p "$SWARM_DIR/parts"
MANIFEST="$SWARM_DIR/manifest.tsv"
: > "$MANIFEST"
rm -f "$SWARM_DIR/.limit" "$SWARM_DIR/.pids"
echo "$BASE_SHA" > "$SWARM_DIR/base_sha"

log(){ echo "[$(date -u +%H:%M:%S)] $*" >> "$SWARM_DIR/swarm.log"; }
log "рій $SWARM_ID стартував: $LANE_N лейнів, base=$(echo "$BASE_SHA" | cut -c1-7), dryrun=$DRYRUN, maxpar=$MAXPAR, lane_timeout=${LANE_TIMEOUT}s"

# --- Пре-фліт оцінка (best-effort): перша лейн-модель/task.md як проксі одного лейна ---
PREFLIGHT=""
CC_ESTIMATE_SH=${CC_ESTIMATE_SH:-$BIN/cc-estimate.sh}
CC_TG_FORMAT_SH=${CC_TG_FORMAT_SH:-$BIN/cc-tg-format.sh}
if [ -f "$CC_ESTIMATE_SH" ]; then
  FIRST_MODEL=$(awk -F'|' '$1!="" && $1!~/^#/{print ($4==""?"haiku":$4); exit}' "$PLAN_ABS")
  FIRST_TASK=$(awk -F'|' '$1!="" && $1!~/^#/{print $2; exit}' "$PLAN_ABS")
  case "$FIRST_MODEL" in local:*) FIRST_MODEL=haiku ;; esac
  PREFLIGHT=$(sh "$CC_ESTIMATE_SH" --task "$FIRST_TASK" --model "$FIRST_MODEL" --lanes "$LANE_N" --maxpar "$MAXPAR" --run-id "$SWARM_ID" 2>/dev/null)
  [ -n "$PREFLIGHT" ] && log "$PREFLIGHT"
fi

PREFLIGHT_TG=""
VARLINE=$(printf '%s\n' "$PREFLIGHT" | grep '^VARS: ' | head -1)
if [ -n "$VARLINE" ] && [ -x "$CC_TG_FORMAT_SH" ]; then
  V_TOKENS=$(printf '%s' "$VARLINE" | sed -n 's/.*TOKENS=\([0-9]*\).*/\1/p')
  V_PCT5H=$(printf '%s' "$VARLINE" | sed -n 's/.*PCT5H=\([0-9.]*\).*/\1/p')
  V_PCT7D=$(printf '%s' "$VARLINE" | sed -n 's/.*PCT7D=\([0-9.]*\).*/\1/p')
  V_MIN=$(printf '%s' "$VARLINE" | sed -n 's/.*MINUTES=\([0-9.]*\).*/\1/p')
  V_BASISN=$(printf '%s' "$VARLINE" | sed -n 's/.*BASIS_N=\([0-9]*\).*/\1/p')
  V_BASISERR=$(printf '%s' "$VARLINE" | sed -n 's/.*BASIS_ERR=\([0-9]*\).*/\1/p')
  V_CONF=$(printf '%s' "$VARLINE" | sed -n 's/.*CONF=\([^ ]*\).*/\1/p')
  FIRST_TIER=$FIRST_MODEL
  PREFLIGHT_TG=$(sh "$CC_TG_FORMAT_SH" preflight --id "$SWARM_ID" \
    --tokens "${V_TOKENS:-0}" --pct5h "${V_PCT5H:-0}" --pct7d "${V_PCT7D:-0}" \
    --minutes "${V_MIN:-0}" --lanes "$LANE_N" --tier "$FIRST_TIER" --maxpar "$MAXPAR" \
    --basis-runs "${V_BASISN:-0}" --basis-err "${V_BASISERR:-}" --confidence "${V_CONF:-низька}" 2>/dev/null)
fi

if [ -n "$PREFLIGHT_TG" ]; then
  notify "$PREFLIGHT_TG"
else
  notify "swarm $SWARM_ID: старт — $LANE_N лейнів, base $(echo "$BASE_SHA" | cut -c1-7)${PREFLIGHT:+ | $PREFLIGHT}"
fi

# --- π-розсіювання (§5 SKILL.md): {PI_DIGIT} у task.md -> цифра π за індексом лейна ---
PI_DIGITS="3 1 4 1 5 9 2 6 5 3 5 8 9 7 9 3 2 3 8 4 6 2 6 4 3 3 8 3 2 7"
pi_digit(){
  IDX=$1
  N=$(echo "$PI_DIGITS" | wc -w)
  [ "$IDX" -ge "$N" ] && log "π-розсіювання: лейн $IDX >= $N цифр у масиві, цикл по колу"
  POS=$((IDX % N + 1))
  echo "$PI_DIGITS" | cut -d' ' -f"$POS"
}

# --- 2/3/4. Спавн лейнів у worktree, зі стелею паралельності ---
run_lane(){
  slug=$1; task=$2; verify=$3; model=${4:-haiku}; style=${5:-none}; idx=${6:-0}; backend=${7:-}
  [ -n "$backend" ] || backend=$CC_BACKEND
  PART="$SWARM_DIR/parts/$slug.tsv"
  WT="$SWARM_DIR/$slug"
  BRANCH="cc/$SWARM_ID/$slug"
  d="$RUNS/${SWARM_ID}-${slug}"
  mkdir -p "$d"
  cp "$task" "$d/task.md"
  if grep -q '{PI_DIGIT}' "$d/task.md" 2>/dev/null; then
    DIGIT=$(pi_digit "$idx")
    sed -i "s/{PI_DIGIT}/$DIGIT/g" "$d/task.md"
  fi

  if [ "$DRYRUN" = "1" ]; then
    printf '%s\tdryrun\tdryrun\tok\tDRYRUN — лейн не спавнено\n' "$slug" > "$PART"
    return 0
  fi

  if [ -e "$SWARM_DIR/.limit" ]; then
    log "$slug: пропущено — рій уже зупинено (session limit)"
    printf '%s\t-\t-\tskipped\tsession limit до старту цього лейна\n' "$slug" > "$PART"
    return 0
  fi

  git -C "$REPO_ABS" worktree add "$WT" -b "$BRANCH" "$BASE_SHA" > "$d/worktree.log" 2>&1 \
    || { printf '%s\t-\t-\tfail\tgit worktree add впав\n' "$slug" > "$PART"; return 2; }

  case "$model" in
    local:*)
      cd "$WT" || { printf '%s\t-\t-\tfail\tcd worktree впав\n' "$slug" > "$PART"; return 2; }
      TAG=$model MODEL=${model#local:} timeout "${LANE_TIMEOUT}s" sh "$CC_LANE_LOCAL_SH" "$d" "$style" "$model" > "$d/lane.log" 2>&1
      RC=$?
      ;;
    *)
      cd "$WT" || { printf '%s\t-\t-\tfail\tcd worktree впав\n' "$slug" > "$PART"; return 2; }
      CC_TELEMETRY_KIND=lane CC_PARENT_RUN_ID="$SWARM_ID" \
        timeout "${LANE_TIMEOUT}s" sh "$CC_RUN_SH" "$d" "$style" "$model" "$backend" > "$d/lane.log" 2>&1
      RC=$?
      ;;
  esac

  if [ "$RC" = "124" ]; then
    printf '%s\t%s\t-\ttimeout\tлейн вбито по LANE_TIMEOUT=%ss\n' "$slug" "$RC" "$LANE_TIMEOUT" > "$PART"
    return 2
  fi
  if [ "$RC" = "3" ]; then
    : > "$SWARM_DIR/.limit"
    printf '%s\t%s\t-\tlimit\tsession limit у cc-run.sh\n' "$slug" "$RC" > "$PART"
    return 3
  fi
  if [ "$RC" != "0" ]; then
    printf '%s\t%s\t-\tfail\tRESULT!=ok (exit %s)\n' "$slug" "$RC" "$RC" > "$PART"
    return 2
  fi

  VSTART=$(date +%s)
  ( cd "$WT" && eval "$verify" ) > "$d/verify.log" 2>&1
  VRC=$?
  VDUR=$(( $(date +%s) - VSTART ))
  CC_TELEMETRY_SH=${CC_TELEMETRY_SH:-$BIN/cc-telemetry.sh}
  [ -x "$CC_TELEMETRY_SH" ] && sh "$CC_TELEMETRY_SH" verification "$d" "$verify" "$VRC" "$VDUR" >/dev/null 2>&1 || true
  if [ "$VRC" = "0" ]; then
    printf '%s\t%s\t%s\tok\t-\n' "$slug" "$RC" "$VRC" > "$PART"
    return 0
  else
    printf '%s\t%s\t%s\tfail\tverify-cmd впав\n' "$slug" "$RC" "$VRC" > "$PART"
    return 2
  fi
}

PIDS_FILE="$SWARM_DIR/.pids"
: > "$PIDS_FILE"
RUNNING=0

wait_for_slot(){
  while [ "$RUNNING" -ge "$MAXPAR" ]; do
    sleep 1
    ALIVE=0
    TMP="$PIDS_FILE.tmp"
    : > "$TMP"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if kill -0 "$p" 2>/dev/null; then
        ALIVE=$((ALIVE+1))
        echo "$p" >> "$TMP"
      fi
    done < "$PIDS_FILE"
    mv "$TMP" "$PIDS_FILE"
    RUNNING=$ALIVE
  done
}

LANE_IDX=0
while IFS='|' read -r slug task verify model style backend_raw; do
  [ -n "${slug:-}" ] || continue
  case "$slug" in \#*) continue ;; esac

  wait_for_slot

  run_lane "$slug" "$task" "$verify" "${model:-haiku}" "${style:-none}" "$LANE_IDX" "${backend_raw:-$CC_BACKEND}" &
  echo "$!" >> "$PIDS_FILE"
  RUNNING=$((RUNNING+1))
  LANE_IDX=$((LANE_IDX+1))
done < "$PLAN_ABS"
wait

# --- Зібрати маніфест з part-файлів (кожен лейн писав у власний файл — без гонки) ---
for slug in $SLUGS; do
  [ -f "$SWARM_DIR/parts/$slug.tsv" ] && cat "$SWARM_DIR/parts/$slug.tsv" >> "$MANIFEST"
done

LIMIT_HIT=0
[ -e "$SWARM_DIR/.limit" ] && LIMIT_HIT=1
grep -q "	limit	" "$MANIFEST" 2>/dev/null && LIMIT_HIT=1

OK_N=$(awk -F'\t' '$4=="ok"{c++} END{print c+0}' "$MANIFEST")
FAIL_N=$(awk -F'\t' '$4=="fail" || $4=="timeout"{c++} END{print c+0}' "$MANIFEST")
FAIL_LIST=$(awk -F'\t' '$4=="fail" || $4=="timeout"{print $1}' "$MANIFEST" | tr '\n' ' ')

if [ "$LIMIT_HIT" = "1" ]; then
  log "рій зупинено: session limit ($OK_N/$LANE_N ok до зупинки)"
  notify "swarm $SWARM_ID: ⛔ SESSION LIMIT — $OK_N/$LANE_N ok до зупинки, exit 3"
  echo "worktree remove для прибирання: git -C $REPO_ABS worktree list --porcelain | awk -v d=\"$SWARM_DIR\" '\$1==\"worktree\" && index(\$2,d)==1{print \$2}' | xargs -r -n1 git -C $REPO_ABS worktree remove --force" >> "$SWARM_DIR/swarm.log"
  telemetry_self limit
  exit 3
fi

# --- 7. Fan-in ---
FANIN_RC=0
FANIN_FILE="${PLAN_ABS}.fanin"
if [ -f "$FANIN_FILE" ] && [ "$DRYRUN" != "1" ]; then
  FANIN_BRANCH="cc/$SWARM_ID/fanin"
  FANIN_WT="$SWARM_DIR/fanin"
  git -C "$REPO_ABS" worktree add "$FANIN_WT" -b "$FANIN_BRANCH" "$BASE_SHA" > "$SWARM_DIR/fanin-worktree.log" 2>&1
  MERGE_FAILS=""
  while IFS='|' read -r slug task verify model style backend_raw; do
    [ -n "${slug:-}" ] || continue
    case "$slug" in \#*) continue ;; esac
    STATUS=$(awk -F'\t' -v s="$slug" '$1==s{print $4}' "$MANIFEST")
    [ "$STATUS" = "ok" ] || continue
    ( cd "$FANIN_WT" && git merge --no-edit "cc/$SWARM_ID/$slug" ) >> "$SWARM_DIR/fanin-merge.log" 2>&1
    if [ $? -ne 0 ]; then
      ( cd "$FANIN_WT" && git merge --abort ) >> "$SWARM_DIR/fanin-merge.log" 2>&1
      MERGE_FAILS="$MERGE_FAILS $slug"
    fi
  done < "$PLAN_ABS"

  if [ -n "$MERGE_FAILS" ]; then
    NEWMANIFEST="$MANIFEST.new"
    : > "$NEWMANIFEST"
    while IFS='	' read -r slug rc vrc status note; do
      case " $MERGE_FAILS " in
        *" $slug "*) printf '%s\t%s\t%s\tfail\tмерж-конфлікт у fan-in\n' "$slug" "$rc" "$vrc" >> "$NEWMANIFEST" ;;
        *) printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$rc" "$vrc" "$status" "$note" >> "$NEWMANIFEST" ;;
      esac
    done < "$MANIFEST"
    mv "$NEWMANIFEST" "$MANIFEST"
    log "fan-in: конфлікт мержу, не увійшли:$MERGE_FAILS"
  fi

  cp "$MANIFEST" "$FANIN_WT/INBOX.tsv"
  FANIN_D="$RUNS/${SWARM_ID}-fanin"
  mkdir -p "$FANIN_D"
  cp "$FANIN_FILE" "$FANIN_D/task.md"
  ( cd "$FANIN_WT" && CC_TELEMETRY_KIND=fanin CC_PARENT_RUN_ID="$SWARM_ID" \
    timeout "${LANE_TIMEOUT}s" sh "$CC_RUN_SH" "$FANIN_D" none sonnet "$CC_BACKEND" ) > "$FANIN_D/lane.log" 2>&1
  FANIN_RC=$?
fi

OK_N=$(awk -F'\t' '$4=="ok"{c++} END{print c+0}' "$MANIFEST")
FAIL_N=$(awk -F'\t' '$4=="fail" || $4=="timeout"{c++} END{print c+0}' "$MANIFEST")
FAIL_LIST=$(awk -F'\t' '$4=="fail" || $4=="timeout"{print $1}' "$MANIFEST" | tr '\n' ' ')

log "рій завершено: $OK_N/$LANE_N ok, fanin_rc=$FANIN_RC"
if [ "$FAIL_N" -eq 0 ] && [ "$FANIN_RC" = "0" ]; then
  telemetry_self ok
  FACT=$(fact_block "$OK_N" "$LANE_N")
  notify "${FACT:-swarm $SWARM_ID: ✅ $OK_N/$LANE_N ok, fan-in ok}"
  echo "worktree remove для прибирання: git -C $REPO_ABS worktree list --porcelain | awk -v d=\"$SWARM_DIR\" '\$1==\"worktree\" && index(\$2,d)==1{print \$2}' | xargs -r -n1 git -C $REPO_ABS worktree remove --force" >> "$SWARM_DIR/swarm.log"
  exit 0
else
  telemetry_self fail
  FACT=$(fact_block "$OK_N" "$LANE_N")
  notify "${FACT:-swarm $SWARM_ID: ❌ $OK_N/$LANE_N ok, fails:${FAIL_LIST:- -}, fanin_rc=$FANIN_RC}"
  echo "worktree remove для прибирання: git -C $REPO_ABS worktree list --porcelain | awk -v d=\"$SWARM_DIR\" '\$1==\"worktree\" && index(\$2,d)==1{print \$2}' | xargs -r -n1 git -C $REPO_ABS worktree remove --force" >> "$SWARM_DIR/swarm.log"
  exit 2
fi
