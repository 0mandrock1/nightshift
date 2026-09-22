#!/bin/sh
# Пре-фліт оцінка вартості рану/рою ДО спавну. Друкує рівно один PREFLIGHT-блок
# (придатний і для логу, і для вставки в чат) і, якщо дали --run-id, пише рядок
# у swarm.estimates для подальшої звірки з фактом (cc-telemetry.sh дописує actual_*).
#
#   sh cc-estimate.sh --task <task.md> --model <m> [--lanes N] [--maxpar K] [--run-id ID]
#
# Кепи читаються з /root/projects/tg_bots/mandrock0_cc_bot/.env
# (P5H_TOKEN_CAP / P7D_TOKEN_CAP), дефолти 14200000 / 200000000 якщо файл/змінні
# відсутні (позначається в рядку "базис").
#
# Основа прогнозу — медіана swarm.runs по цій моделі (kind run|lane, status=ok),
# БЕЗ скейлу за розміром task.md (виявлено 03.09.2026: скейл за
# рядками/файл-шляхами task.md не корелює з фактом — токени факт/предикт
# 0.06x-5.66x, хвилини 0.32x-11.7x на реальних ранах). ±% у "базис" — це
# реальний напів-IQR токенів відносно медіани (50*(p75-p25)/медіана), не
# фіксоване число. Історія < 3 ранів на модель -> сідові значення нижче,
# впевненість позначається низькою.
#
# Best-effort: недоступна БД чи Docker -> сідові значення, скрипт все одно
# друкує PREFLIGHT і завершується 0 (це інструмент оцінки, не гейт).
set -u

MODEL=""; TASK=""; LANES=1; MAXPAR=4; RUN_ID=""
COMPARE=0; CHAIN_TASK=""; CHAIN_MODEL="sonnet"; COMPACT_HTML=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK=$2; shift 2 ;;
    --model) MODEL=$2; shift 2 ;;
    --lanes) LANES=$2; shift 2 ;;
    --maxpar) MAXPAR=$2; shift 2 ;;
    --run-id) RUN_ID=$2; shift 2 ;;
    --compact-html) COMPACT_HTML=1; shift ;;
    --compare) COMPARE=1; shift ;;
    --chain-task) CHAIN_TASK=$2; shift 2 ;;
    --chain-model) CHAIN_MODEL=$2; shift 2 ;;
    *) echo "cc-estimate: невідомий аргумент $1" >&2; exit 1 ;;
  esac
done
[ -n "$TASK" ] || { echo "cc-estimate: --task обов'язковий" >&2; exit 1; }
[ -n "$MODEL" ] || { echo "cc-estimate: --model обов'язковий" >&2; exit 1; }
[ -f "$TASK" ] || { echo "cc-estimate: нема task-файлу $TASK" >&2; exit 1; }
if [ "$COMPARE" = "1" ]; then
  [ -n "$CHAIN_TASK" ] || { echo "cc-estimate: --compare вимагає --chain-task" >&2; exit 1; }
  [ -f "$CHAIN_TASK" ] || { echo "cc-estimate: нема chain-task-файлу $CHAIN_TASK" >&2; exit 1; }
fi

CAP_ENV=${CC_CAP_ENV:-/root/projects/tg_bots/mandrock0_cc_bot/.env}
CREDS=${CC_PG_CREDS:-/root/ops/cc-runs/creds-pg.env}
PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
PG_DB=${CC_PG_DB:-mandrock_kb}
PG_USER=${CC_PG_USER:-mandrock}
PG_HOST=${CC_PG_HOST:-127.0.0.1}
PG_PORT=${CC_PG_PORT:-5432}

# --- кепи ---
CAP_BASIS="кепи з $CAP_ENV"
if [ -f "$CAP_ENV" ]; then
  P5H_CAP=$(grep -E '^P5H_TOKEN_CAP=' "$CAP_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
  P7D_CAP=$(grep -E '^P7D_TOKEN_CAP=' "$CAP_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
fi
if [ -z "${P5H_CAP:-}" ] || [ -z "${P7D_CAP:-}" ]; then
  P5H_CAP=${P5H_CAP:-14200000}
  P7D_CAP=${P7D_CAP:-200000000}
  CAP_BASIS="дефолтні кепи"
fi

# --- сідові значення (тільки холодний старт, історія < 3 ранів) ---
seed_tokens_in(){ case "$1" in sonnet) echo 11500000 ;; opus) echo 1000000 ;; haiku) echo 400000 ;; *) echo 400000 ;; esac; }
seed_tokens_out(){ case "$1" in sonnet) echo 48000 ;; opus) echo 20000 ;; haiku) echo 6000 ;; *) echo 6000 ;; esac; }
seed_minutes(){ case "$1" in sonnet) echo 5.5 ;; opus) echo 0 ;; haiku) echo 1.5 ;; *) echo 1.5 ;; esac; }

# напів-IQR у % від медіани: 50*(p75-p25)/медіана, 0 якщо медіана<=0
iqr_pct(){
  awk -v med="$1" -v p25="$2" -v p75="$3" 'BEGIN{
    if (med+0 <= 0) { print 0; exit }
    v = 50.0*(p75-p25)/med;
    if (v < 0) v = 0;
    printf "%.0f", v
  }'
}

# --- історія з БД (best-effort): медіана + p25/p75 tokens і duration ---
HIST_N=0; HIST_TOK=0; HIST_TOK_P25=0; HIST_TOK_P75=0
HIST_MIN_S=0; HIST_MIN_P25_S=0; HIST_MIN_P75_S=0
if [ -f "$CREDS" ] && command -v docker >/dev/null 2>&1; then
  PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
  if [ -n "${PGPASSWORD:-}" ]; then
    OUT=$(docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
      psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tAc \
      "SELECT count(*),
        coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_s),0),
        coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY duration_s),0),
        coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY duration_s),0)
       FROM swarm.runs WHERE model='${MODEL}' AND kind IN ('run','lane') AND status='ok';" \
      2>/dev/null)
    if [ -n "$OUT" ]; then
      HIST_N=$(echo "$OUT" | cut -d'|' -f1 | tr -d '[:space:]')
      HIST_TOK=$(echo "$OUT" | cut -d'|' -f2 | tr -d '[:space:]')
      HIST_TOK_P25=$(echo "$OUT" | cut -d'|' -f3 | tr -d '[:space:]')
      HIST_TOK_P75=$(echo "$OUT" | cut -d'|' -f4 | tr -d '[:space:]')
      HIST_MIN_S=$(echo "$OUT" | cut -d'|' -f5 | tr -d '[:space:]')
      HIST_MIN_P25_S=$(echo "$OUT" | cut -d'|' -f6 | tr -d '[:space:]')
      HIST_MIN_P75_S=$(echo "$OUT" | cut -d'|' -f7 | tr -d '[:space:]')
    fi
  fi
fi
HIST_N=${HIST_N:-0}
case "$HIST_N" in ''|*[!0-9]*) HIST_N=0 ;; esac

if [ "$HIST_N" -ge 3 ]; then
  BASE_TOKENS=$HIST_TOK
  BASE_MIN=$(awk -v s="$HIST_MIN_S" 'BEGIN{printf "%.2f", s/60.0}')
  CONF="висока"
  TOK_PCT=$(iqr_pct "$HIST_TOK" "$HIST_TOK_P25" "$HIST_TOK_P75")
  BASIS="медіана $HIST_N ранів $MODEL, ±${TOK_PCT}%"
else
  BASE_TOKENS=$(( $(seed_tokens_in "$MODEL") + $(seed_tokens_out "$MODEL") ))
  BASE_MIN=$(seed_minutes "$MODEL")
  CONF="низька"
  TOK_PCT=""
  BASIS="сідові значення (історія <3 ранів $MODEL)"
fi

PER_LANE_TOKENS=$BASE_TOKENS
PER_LANE_MIN=$BASE_MIN

if [ "$LANES" -gt 1 ] 2>/dev/null; then
  FANIN_TOKENS=$(( $(seed_tokens_in sonnet) + $(seed_tokens_out sonnet) ))
  FANIN_MIN=$(seed_minutes sonnet)
  TOTAL_TOKENS=$(awk -v pl="$PER_LANE_TOKENS" -v n="$LANES" -v fi="$FANIN_TOKENS" 'BEGIN{printf "%.0f", pl*n+fi}')
  WAVES=$(awk -v n="$LANES" -v k="$MAXPAR" 'BEGIN{w=int((n+k-1)/k); if(w<1)w=1; print w}')
  TOTAL_MIN=$(awk -v pl="$PER_LANE_MIN" -v w="$WAVES" -v fi="$FANIN_MIN" 'BEGIN{printf "%.1f", pl*w+fi}')
else
  TOTAL_TOKENS=$PER_LANE_TOKENS
  TOTAL_MIN=$PER_LANE_MIN
fi

PCT_5H=$(awk -v t="$TOTAL_TOKENS" -v c="$P5H_CAP" 'BEGIN{printf "%.1f", (c>0)?(100.0*t/c):0}')
PCT_7D=$(awk -v t="$TOTAL_TOKENS" -v c="$P7D_CAP" 'BEGIN{printf "%.1f", (c>0)?(100.0*t/c):0}')

# --- РЕАЛЬНИЙ % завантаження вікон із заголовків Anthropic (best-effort, ЛИШЕ для показу) ---
RL5_PCT=""; RL7_PCT=""; RL_SOURCE=""
USAGE_CLI=${CC_USAGE_CLI:-/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js}
if command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$USAGE_CLI" ]; then
  RLJSON=$(node "$USAGE_CLI" --ratelimit-json 2>/dev/null)
  if [ -n "$RLJSON" ]; then
    U5=$(printf '%s' "$RLJSON" | jq -r '.util5h // empty' 2>/dev/null)
    U7=$(printf '%s' "$RLJSON" | jq -r '.util7d // empty' 2>/dev/null)
    RL_SOURCE=$(printf '%s' "$RLJSON" | jq -r '.source // empty' 2>/dev/null)
    case "$U5" in ''|*[!0-9.]*) ;; *) RL5_PCT=$(awk -v u="$U5" 'BEGIN{printf "%.1f", u*100}') ;; esac
    case "$U7" in ''|*[!0-9.]*) ;; *) RL7_PCT=$(awk -v u="$U7" 'BEGIN{printf "%.1f", u*100}') ;; esac
  fi
fi

bar_pct(){
  awk -v p="$1" 'BEGIN{
    w=12; r=p/100.0; if(r<0)r=0;
    fill=int((r<1?r:1)*w+0.5); if(fill>w)fill=w;
    s=""; for(i=0;i<fill;i++)s=s"█"; for(i=fill;i<w;i++)s=s"░";
    lbl=(p>100)?">100%":sprintf("%d%%",int(p+0.5));
    printf "%s %5s", s, lbl;
  }'
}

fmt_tokens(){
  awk -v n="$1" 'BEGIN{
    if (n>=1000000) printf "%.1fM", n/1000000.0;
    else if (n>=1000) printf "%.0fk", n/1000.0;
    else printf "%d", n
  }'
}
TOK_H=$(fmt_tokens "$TOTAL_TOKENS")

if [ "$COMPACT_HTML" = "1" ]; then
  if [ "$HIST_N" -ge 3 ]; then
    BASIS_H="${MODEL} · ${HIST_N} ранів · ±${TOK_PCT}%"
  else
    BASIS_H="${MODEL} · сід (<3 ранів)"
  fi
  if [ "$RL_SOURCE" = "stale" ]; then
    BASIS_H="${BASIS_H} · ⚠ ліміт з протухлого кешу"
  elif [ -z "$RL5_PCT" ]; then
    BASIS_H="${BASIS_H} · ⚠ без реального %"
  fi
  printf '<pre>\n'
  printf 'токени    %s\n' "~${TOK_H}"
  if [ -n "$RL5_PCT" ]; then printf '5h-вікно  %s\n' "$(bar_pct "$RL5_PCT")"; else printf '5h-вікно  %s\n' "н/д"; fi
  if [ -n "$RL7_PCT" ]; then printf 'тиждень   %s\n' "$(bar_pct "$RL7_PCT")"; else printf 'тиждень   %s\n' "н/д"; fi
  printf 'хв        %s\n' "~${TOTAL_MIN}"
  printf 'базис     %s\n' "${BASIS_H}"
  printf '</pre>'
  exit 0
fi

echo "PREFLIGHT: ~${TOK_H} токенів | ${PCT_5H}% 5h-вікна | ${PCT_7D}% тижня | ~${TOTAL_MIN} хв wall-clock"
echo "базис: ${BASIS} | впевненість: ${CONF} | ${CAP_BASIS}"
awk -v p="$PCT_7D" 'BEGIN{ if (p+0 > 40) print "PREFLIGHT: ⚠ дорого" }'
BASIS_ERR=""
[ "$HIST_N" -ge 3 ] && BASIS_ERR=$TOK_PCT
echo "VARS: TOKENS=$TOTAL_TOKENS PCT5H=$PCT_5H PCT7D=$PCT_7D MINUTES=$TOTAL_MIN BASIS_N=$HIST_N BASIS_ERR=$BASIS_ERR CONF=$CONF"

# --- --compare: той самий обсяг роботи як ланцюг N послідовних кроків ---
if [ "$COMPARE" = "1" ]; then
  CHAIN_HIST_N=0; CHAIN_HIST_TOK=0; CHAIN_HIST_TOK_P25=0; CHAIN_HIST_TOK_P75=0
  CHAIN_HIST_MIN_S=0
  if [ -f "$CREDS" ] && command -v docker >/dev/null 2>&1 && [ -n "${PGPASSWORD:-}" ]; then
    COUT=$(docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
      psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tAc \
      "SELECT count(*),
        coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
        coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_s),0)
       FROM swarm.runs WHERE model='${CHAIN_MODEL}' AND kind IN ('run','lane','chain') AND status='ok';" \
      2>/dev/null)
    if [ -n "$COUT" ]; then
      CHAIN_HIST_N=$(echo "$COUT" | cut -d'|' -f1 | tr -d '[:space:]')
      CHAIN_HIST_TOK=$(echo "$COUT" | cut -d'|' -f2 | tr -d '[:space:]')
      CHAIN_HIST_TOK_P25=$(echo "$COUT" | cut -d'|' -f3 | tr -d '[:space:]')
      CHAIN_HIST_TOK_P75=$(echo "$COUT" | cut -d'|' -f4 | tr -d '[:space:]')
      CHAIN_HIST_MIN_S=$(echo "$COUT" | cut -d'|' -f5 | tr -d '[:space:]')
    fi
  fi
  CHAIN_HIST_N=${CHAIN_HIST_N:-0}
  case "$CHAIN_HIST_N" in ''|*[!0-9]*) CHAIN_HIST_N=0 ;; esac

  if [ "$CHAIN_HIST_N" -ge 3 ]; then
    CHAIN_BASE_TOKENS=$CHAIN_HIST_TOK
    CHAIN_BASE_MIN=$(awk -v s="$CHAIN_HIST_MIN_S" 'BEGIN{printf "%.2f", s/60.0}')
    CHAIN_CONF="висока"
    CHAIN_PCT=$(iqr_pct "$CHAIN_HIST_TOK" "$CHAIN_HIST_TOK_P25" "$CHAIN_HIST_TOK_P75")
    CHAIN_BASIS="медіана $CHAIN_HIST_N ранів $CHAIN_MODEL, ±${CHAIN_PCT}%"
  else
    CHAIN_BASE_TOKENS=$(( $(seed_tokens_in "$CHAIN_MODEL") + $(seed_tokens_out "$CHAIN_MODEL") ))
    CHAIN_BASE_MIN=$(seed_minutes "$CHAIN_MODEL")
    CHAIN_CONF="низька"
    CHAIN_BASIS="сідові значення (історія <3 ранів $CHAIN_MODEL)"
  fi

  CHAIN_STEP_TOKENS=$CHAIN_BASE_TOKENS
  CHAIN_STEP_MIN=$CHAIN_BASE_MIN
  CHAIN_TOTAL_TOKENS=$(awk -v st="$CHAIN_STEP_TOKENS" -v n="$LANES" 'BEGIN{printf "%.0f", st*n}')
  CHAIN_TOTAL_MIN=$(awk -v sm="$CHAIN_STEP_MIN" -v n="$LANES" 'BEGIN{printf "%.1f", sm*n}')
  CHAIN_PCT_7D=$(awk -v t="$CHAIN_TOTAL_TOKENS" -v c="$P7D_CAP" 'BEGIN{printf "%.1f", (c>0)?(100.0*t/c):0}')
  CHAIN_TOK_H=$(fmt_tokens "$CHAIN_TOTAL_TOKENS")

  echo "COMPARE: рій ~${TOK_H} токенів / ~${TOTAL_MIN} хв  vs  ланцюг(${LANES}×${CHAIN_MODEL}) ~${CHAIN_TOK_H} токенів / ~${CHAIN_TOTAL_MIN} хв"
  echo "COMPARE: базис ланцюга — ${CHAIN_BASIS} | впевненість: ${CHAIN_CONF} | ${CHAIN_PCT_7D}% тижня"
  if [ "$CHAIN_TOTAL_TOKENS" -lt "$TOTAL_TOKENS" ] 2>/dev/null; then
    echo "COMPARE: переможець за токенами — ланцюг"
  elif [ "$CHAIN_TOTAL_TOKENS" -gt "$TOTAL_TOKENS" ] 2>/dev/null; then
    echo "COMPARE: переможець за токенами — рій"
  else
    echo "COMPARE: нічия за токенами"
  fi
fi

# --- запис у swarm.estimates ДО запуску (лише якщо дали --run-id) ---
if [ -n "$RUN_ID" ] && [ -f "$CREDS" ] && command -v docker >/dev/null 2>&1 && [ -n "${PGPASSWORD:-}" ]; then
  SQL="INSERT INTO swarm.estimates (run_id, predicted_tokens, predicted_minutes, predicted_pct_5h, predicted_pct_week, estimator_version) VALUES ('$(printf '%s' "$RUN_ID" | sed "s/'/''/g")', $TOTAL_TOKENS, $TOTAL_MIN, $PCT_5H, $PCT_7D, 'cc-estimate/2');"
  echo "$SQL" | docker exec -i -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q \
    >/root/ops/cc-runs/telemetry.log.est 2>&1 || true
fi

exit 0
