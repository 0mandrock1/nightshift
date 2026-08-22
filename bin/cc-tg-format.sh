#!/bin/sh
# Рендер PREFLIGHT/FACT-блоків для Telegram HTML (parse_mode=HTML), під
# конвенції /root/projects/tg_bots/mandrock0_cc_bot/usage.js: MAXW=42
# всередині <pre>, емодзі ПОЗА <pre>, fmtTokens-стиль скорочення 8.7M/1.2k.
# Читай, не змінюй usage.js — тільки формат/конвенції звідти.
#
#   sh cc-tg-format.sh preflight --id ID --tokens N --pct5h P --pct7d P \
#     --minutes M --lanes L --tier T --maxpar K --basis-runs K --basis-err E \
#     --confidence C [--single]
#   sh cc-tg-format.sh fact --id ID --ok N --total N \
#     --actual-tokens N --predicted-tokens N --actual-minutes M --predicted-minutes M \
#     --basis-runs K --basis-err E
#
# --single (тільки preflight) — одиночний cc-run.sh/cc-chain.sh: той самий
#   формат, без рядка "склад" (немає лейнів).
# Друкує готовий HTML-блок на stdout, придатний для передачі в notify().
set -u

fmt_tokens(){
  awk -v n="$1" 'BEGIN{
    if (n>=1000000) printf "%.1fM", n/1000000.0;
    else if (n>=1000) printf "%.1fk", n/1000.0;
    else printf "%d", n+0
  }' | sed 's/\.0M/M/; s/\.0k/k/'
}

# Бар 10-символьний, ▓×round(P/10) + ░×решта, капується на 10 навіть якщо P>100.
bar10(){
  awk -v p="$1" 'BEGIN{
    p+=0; if (p<0) p=0;
    fill = int(p/10.0 + 0.5);
    if (fill > 10) fill = 10;
    s = "";
    for (i=0; i<fill; i++) s = s "▓";
    for (i=fill; i<10; i++) s = s "░";
    printf "%s", s
  }'
}

esc(){
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

pct_or_dash(){ [ -n "${1:-}" ] && printf '%s%%' "$1" || printf '?%%'; }

case "${1:-}" in
  preflight)
    shift
    ID=""; TOKENS=0; PCT5H=0; PCT7D=0; MINUTES=0; LANES=""; TIER=""; MAXPAR=""
    BASIS_RUNS=0; BASIS_ERR=""; CONF="низька"; SINGLE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) ID=$2; shift 2 ;;
        --tokens) TOKENS=$2; shift 2 ;;
        --pct5h) PCT5H=$2; shift 2 ;;
        --pct7d) PCT7D=$2; shift 2 ;;
        --minutes) MINUTES=$2; shift 2 ;;
        --lanes) LANES=$2; shift 2 ;;
        --tier) TIER=$2; shift 2 ;;
        --maxpar) MAXPAR=$2; shift 2 ;;
        --basis-runs) BASIS_RUNS=$2; shift 2 ;;
        --basis-err) BASIS_ERR=$2; shift 2 ;;
        --confidence) CONF=$2; shift 2 ;;
        --single) SINGLE=1; shift ;;
        *) echo "cc-tg-format: невідомий аргумент $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$ID" ] || { echo "cc-tg-format: --id обов'язковий" >&2; exit 1; }

    LABEL="рою"
    [ "$SINGLE" = "1" ] && LABEL="рану"

    B5=$(bar10 "$PCT5H")
    B7=$(bar10 "$PCT7D")
    TOK_H=$(fmt_tokens "$TOKENS")

    OUT="🐝 <b>ПРЕФЛАЙТ · ${LABEL} · $(esc "$ID")</b>"
    OUT="$OUT
<pre>
токени  ~${TOK_H}
  5h    ${B5}  $(pct_or_dash "$PCT5H")  з CAP5H
  тижд  ${B7}  $(pct_or_dash "$PCT7D")  з CAP7D
  час     ~${MINUTES} хв"
    if [ "$SINGLE" != "1" ]; then
      OUT="$OUT
склад   ${LANES}×${TIER} ‖${MAXPAR} + sonnet fan-in"
    fi
    OUT="$OUT
──────────────────────────
базис   медіана ${BASIS_RUNS} ранів, ±$(pct_or_dash "${BASIS_ERR:-}")
довіра  ${CONF}
</pre>"
    echo "$OUT"

    PCT7D_INT=$(awk -v p="$PCT7D" 'BEGIN{printf "%d", p+0}')
    if [ "$PCT7D_INT" -gt 40 ] 2>/dev/null; then
      echo "---WARN---"
      echo "⚠️ <b>понад 40% тижня</b> — підтвердь запуск"
    fi
    ;;

  fact)
    shift
    ID=""; OK=0; TOTAL=0
    ACTUAL_TOK=0; PRED_TOK=0; ACTUAL_MIN=0; PRED_MIN=0
    BASIS_RUNS=0; BASIS_ERR=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) ID=$2; shift 2 ;;
        --ok) OK=$2; shift 2 ;;
        --total) TOTAL=$2; shift 2 ;;
        --actual-tokens) ACTUAL_TOK=$2; shift 2 ;;
        --predicted-tokens) PRED_TOK=$2; shift 2 ;;
        --actual-minutes) ACTUAL_MIN=$2; shift 2 ;;
        --predicted-minutes) PRED_MIN=$2; shift 2 ;;
        --basis-runs) BASIS_RUNS=$2; shift 2 ;;
        --basis-err) BASIS_ERR=$2; shift 2 ;;
        *) echo "cc-tg-format: невідомий аргумент $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$ID" ] || { echo "cc-tg-format: --id обов'язковий" >&2; exit 1; }

    dpct(){
      A=$1; P=$2
      awk -v a="$A" -v p="$P" 'BEGIN{
        if (p+0==0) { print "?"; exit }
        d = 100.0*(a-p)/p;
        sign = (d>=0) ? "+" : "";
        printf "%s%.0f", sign, d
      }'
    }
    DTOK=$(dpct "$ACTUAL_TOK" "$PRED_TOK")
    DMIN=$(dpct "$ACTUAL_MIN" "$PRED_MIN")
    ATOK_H=$(fmt_tokens "$ACTUAL_TOK")
    PTOK_H=$(fmt_tokens "$PRED_TOK")

    echo "✅ <b>ФАКТ · рою · $(esc "$ID") · ${OK}/${TOTAL}</b>
<pre>
токени   ${ATOK_H}   прогноз ${PTOK_H}   ${DTOK}%
час      ${ACTUAL_MIN}хв   прогноз ${PRED_MIN}хв   ${DMIN}%
──────────────────────────
оцінювач: ${BASIS_RUNS} ранів в базі, ±$(pct_or_dash "${BASIS_ERR:-}")
</pre>"
    ;;

  *)
    echo "cc-tg-format: невідома підкоманда '${1:-}' (preflight|fact)" >&2
    exit 1
    ;;
esac
