#!/bin/sh
# Leave-one-out бектест: v1 (точка-медіана ± напів-IQR% токенів, застосований
# як симетрична смуга навколо медіани хвилин — той самий % v1 показував у
# "базис: ±N%") проти v2 (p25-p75 хвилин по model×kind, фолбек model-only,
# n>=5, той самий базис що cc-estimate.sh) — частка ранів, у яких ФАКТ
# (duration_s/60) потрапив у прогнозний інтервал.
#
# Семпл: останні N ok-ранів (out>=300, duration>=60s) на модель, а не вся
# історія — повний leave-one-out per-run psql-запит на кожен з 400+ ранів
# був би повільним; N обмежує це без спотворення висновку (той самий розподіл
# останніх ранів). N друкується в звіті, не приховується.
#
#   sh cc-estimate-backtest.sh [N-на-модель, дефолт 40]
set -u
N=${1:-40}
CC_RUNS=${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}
CREDS=${CC_PG_CREDS:-$CC_RUNS/creds-pg.env}
PG_CONTAINER=${CC_PG_CONTAINER:-mandrock-kb-postgres}
PG_DB=${CC_PG_DB:-mandrock_kb}
PG_USER=${CC_PG_USER:-mandrock}
PG_HOST=${CC_PG_HOST:-127.0.0.1}
PG_PORT=${CC_PG_PORT:-5432}

[ -f "$CREDS" ] || { echo "cc-estimate-backtest: нема креденшлів $CREDS" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "cc-estimate-backtest: нема docker" >&2; exit 1; }
PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-)
[ -n "$PGPASSWORD" ] || { echo "cc-estimate-backtest: порожній POSTGRES_PASSWORD" >&2; exit 1; }

psql_(){ docker exec -e PGPASSWORD="$PGPASSWORD" "$PG_CONTAINER" \
  psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1" 2>/dev/null; }

CANDIDATES=$(psql_ "SELECT run_id, model, task_kind, ROUND((duration_s/60.0)::numeric,2)
  FROM swarm.runs
  WHERE status='ok' AND tokens_out>=300 AND duration_s>=60 AND kind IN ('run','lane')
  ORDER BY started_at DESC LIMIT $((N*3));")

TOTAL=0; V1_HIT=0; V2_HIT=0; V2_HAS_BASIS=0
MODEL_SEEN=""
echo "run_id,model,kind,actual_min,v1_lo,v1_hi,v1_hit,v2_lo,v2_hi,v2_n,v2_hit"
echo "$CANDIDATES" | while IFS='|' read -r RID MODEL KIND AMIN; do
  [ -n "$RID" ] || continue
  # cap N-на-модель: рахуємо скільки вже оброблено на цю модель через лічильник-файл (sh не має асоціативних масивів)
  CNT_FILE="/tmp/.cc-backtest-cnt-$MODEL"
  C=$(cat "$CNT_FILE" 2>/dev/null || echo 0)
  [ "$C" -ge "$N" ] && continue
  echo $((C+1)) > "$CNT_FILE"

  # --- v1: медіана + напів-IQR% токенів (як cc-estimate.sh iqr_pct), виключаючи цей run_id ---
  V1_ROW=$(psql_ "SELECT
      coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_s),0)/60.0,
      coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
      coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0),
      coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY tokens_in+tokens_out),0)
    FROM swarm.runs WHERE model='${MODEL}' AND kind IN ('run','lane') AND status='ok' AND run_id != '${RID}';")
  V1_MEDMIN=$(echo "$V1_ROW" | cut -d'|' -f1)
  V1_MED=$(echo "$V1_ROW" | cut -d'|' -f2); V1_P25=$(echo "$V1_ROW" | cut -d'|' -f3); V1_P75=$(echo "$V1_ROW" | cut -d'|' -f4)
  V1_PCT=$(awk -v med="$V1_MED" -v p25="$V1_P25" -v p75="$V1_P75" 'BEGIN{ if(med+0<=0){print 0;exit} v=50.0*(p75-p25)/med; if(v<0)v=0; printf "%.2f", v}')
  V1_LO=$(awk -v m="$V1_MEDMIN" -v p="$V1_PCT" 'BEGIN{v=m*(1-p/100.0); if(v<0)v=0; printf "%.2f", v}')
  V1_HI=$(awk -v m="$V1_MEDMIN" -v p="$V1_PCT" 'BEGIN{printf "%.2f", m*(1+p/100.0)}')
  V1_H=$(awk -v a="$AMIN" -v lo="$V1_LO" -v hi="$V1_HI" 'BEGIN{print (a>=lo && a<=hi)?1:0}')

  # --- v2: p25-p75 хвилин по model×kind (n>=5, виключаючи self), фолбек model-only ---
  MK_ROW=$(psql_ "SELECT count(*),
      coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY duration_s),0)/60.0,
      coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY duration_s),0)/60.0
    FROM swarm.runs WHERE model='${MODEL}' AND task_kind='${KIND}' AND kind IN ('run','lane') AND status='ok'
      AND tokens_out>=300 AND duration_s>=60 AND (concurrent=0 OR concurrent IS NULL) AND run_id != '${RID}';")
  MK_N=$(echo "$MK_ROW" | cut -d'|' -f1 | tr -d '[:space:]')
  if [ "${MK_N:-0}" -ge 5 ] 2>/dev/null; then
    V2_LO=$(echo "$MK_ROW" | cut -d'|' -f2); V2_HI_=$(echo "$MK_ROW" | cut -d'|' -f3); V2_N=$MK_N
  else
    M_ROW=$(psql_ "SELECT count(*),
        coalesce(percentile_cont(0.25) WITHIN GROUP (ORDER BY duration_s),0)/60.0,
        coalesce(percentile_cont(0.75) WITHIN GROUP (ORDER BY duration_s),0)/60.0
      FROM swarm.runs WHERE model='${MODEL}' AND kind IN ('run','lane') AND status='ok'
        AND tokens_out>=300 AND duration_s>=60 AND (concurrent=0 OR concurrent IS NULL) AND run_id != '${RID}';")
    M_N=$(echo "$M_ROW" | cut -d'|' -f1 | tr -d '[:space:]')
    if [ "${M_N:-0}" -ge 5 ] 2>/dev/null; then
      V2_LO=$(echo "$M_ROW" | cut -d'|' -f2); V2_HI_=$(echo "$M_ROW" | cut -d'|' -f3); V2_N=$M_N
    else
      V2_LO=""; V2_HI_=""; V2_N=0
    fi
  fi
  if [ -n "$V2_LO" ]; then
    V2_H=$(awk -v a="$AMIN" -v lo="$V2_LO" -v hi="$V2_HI_" 'BEGIN{print (a>=lo && a<=hi)?1:0}')
  else
    V2_H="нема_базису"
  fi

  echo "$RID,$MODEL,$KIND,$AMIN,$V1_LO,$V1_HI,$V1_H,${V2_LO:-},${V2_HI_:-},$V2_N,$V2_H"
done | tee /tmp/cc-backtest-detail.csv

rm -f /tmp/.cc-backtest-cnt-*

# --- агрегація з CSV (пропускаємо заголовок) ---
awk -F, 'NR>1{
  total++; if($7=="1") v1hit++;
  if($11=="нема_базису") { nobasis++ } else { withbasis++; if($11=="1") v2hit++ }
}
END{
  printf "TOTAL=%d\n", total
  printf "V1_HIT=%d/%d (%.0f%%)\n", v1hit, total, (total>0)?100.0*v1hit/total:0
  printf "V2_WITH_BASIS=%d (без базису model×kind і model — n<5: %d)\n", withbasis, nobasis
  printf "V2_HIT=%d/%d (%.0f%% з тих, де є базис)\n", v2hit, withbasis, (withbasis>0)?100.0*v2hit/withbasis:0
}' /tmp/cc-backtest-detail.csv
