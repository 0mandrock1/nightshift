#!/bin/sh
# Спільні хелпери для cc-run.sh / cc-chain.sh: калібрування пре-фліт оцінки на
# реальному rate-limit (util5h/util7d), concurrency на старті й категорія
# задачі (kind) для групування model×kind у cc-estimate.sh.
#
#   . cc-util-lib.sh   (джерелити, не виконувати — визначає функції в поточному sh)
#
# ENV: CC_USAGE_CLI (дефолт /root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js)
set -u

# Реальний % завантаження 5h/7d вікон з заголовків Anthropic (той самий шлях,
# що cc-estimate.sh уже використовує для показу поточного %). Best-effort:
# недоступний node/jq/usage-cli чи порожній результат -> три порожні поля
# (SQL NULL нижче в cc-telemetry.sh), викликача це не валить.
# Друкує: "<util5h_0..1|порожньо> <util7d_0..1|порожньо> <source|порожньо>"
cc_util_snapshot(){
  U5=""; U7=""; SRC=""
  USAGE_CLI=${CC_USAGE_CLI:-/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js}
  if command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$USAGE_CLI" ]; then
    RLJSON=$(node "$USAGE_CLI" --ratelimit-json 2>/dev/null)
    if [ -n "$RLJSON" ]; then
      U5=$(printf '%s' "$RLJSON" | jq -r '.util5h // empty' 2>/dev/null)
      U7=$(printf '%s' "$RLJSON" | jq -r '.util7d // empty' 2>/dev/null)
      SRC=$(printf '%s' "$RLJSON" | jq -r '.source // empty' 2>/dev/null)
    fi
  fi
  case "$U5" in ''|*[!0-9.]*) U5="" ;; esac
  case "$U7" in ''|*[!0-9.]*) U7="" ;; esac
  echo "$U5 $U7 $SRC"
}

# К-сть ІНШИХ живих cc-run.sh/cc-chain.sh обгорток на вузлі, крім власного
# процесу (self-count у pgrep -f завжди включає нас самих — віднімаємо 1).
cc_concurrent_others(){
  N=$(pgrep -f 'cc-run\.sh|cc-chain\.sh' 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$N" in ''|*[!0-9]*) N=1 ;; esac
  N=$((N - 1))
  [ "$N" -ge 0 ] || N=0
  echo "$N"
}

# Категорія задачі для group-by model×kind у cc-estimate.sh v2: CC_KIND, якщо
# заданий викликачем, інакше префікс slug до першого "-" (той самий формат,
# що бекфіл історії в 003_estimator_v2.sql — напр. skills-surface -> skills).
cc_task_kind(){
  ID=${1:?run-id}
  if [ -n "${CC_KIND:-}" ]; then
    echo "$CC_KIND"
  else
    echo "${ID%%-*}"
  fi
}

# Вихідні токени рану: usage.json (claude) або events.jsonl turn.completed
# (codex) — той самий облік, що вже рахує CODEX_USAGE у cc-run.sh, лише як
# число, не рядок логу. Друкує ПОРОЖНЬО (не 0!), якщо жодне джерело не дало
# результату — "невідомо" й "підтверджений нуль" мають лишатись різними
# станами для cc_no_work_guard: run-usage.sh відомо може не знайти сесію
# (гонка з файловою системою, чужа сесія теж не факт), і карати гардом за
# власну діагностичну прогалину — хибний позитив на реально хорошому рані.
cc_out_tokens(){
  DIR=${1:?run-dir}; BACKEND=${2:-claude}
  OUT=""
  if [ -f "$DIR/usage.json" ] && command -v jq >/dev/null 2>&1; then
    OUT=$(jq -r '.total_out // empty' "$DIR/usage.json" 2>/dev/null || echo "")
  fi
  case "$OUT" in *[!0-9]*) OUT="" ;; esac
  if [ -z "$OUT" ] && [ "$BACKEND" = "codex" ] && [ -f "$DIR/events.jsonl" ] && command -v jq >/dev/null 2>&1; then
    OUT=$(jq -rs '[.[] | select(.type=="turn.completed") | .usage.output_tokens // 0] | if length==0 then empty else add end' "$DIR/events.jsonl" 2>/dev/null || echo "")
    case "$OUT" in *[!0-9]*) OUT="" ;; esac
  fi
  echo "$OUT"
}

# Останній рядок "CHANGED: ..." у хвості out.log з непорожнім значенням після
# двокрапки. Друкує саме значення (обрізане) або нічого, якщо рядка нема чи
# значення порожнє.
cc_changed_value(){
  DIR=${1:?run-dir}
  tail -40 "$DIR/out.log" 2>/dev/null \
    | grep -aE "^[[:space:]]*\**[[:space:]]*CHANGED:" \
    | tail -1 \
    | sed -E 's/^[[:space:]]*\**[[:space:]]*CHANGED:[[:space:]]*//' \
    | cut -c1-300
}

# Гард «нуль роботи»: якщо в хвості out.log RESULT: ok, але out-токенів < 300
# АБО нема непорожнього CHANGED: — дописує NOTES+RESULT: fail в кінець
# out.log (RESULT лишається останнім рядком) і повертає 0 (guard trips) чи 1
# (RESULT не ok, або все гаразд — run-dir не чіпається). Викликач сам
# вирішує, що робити з exit_code/status далі. Не застосовується до
# fail/timeout/session-limit шляхів — ті вже не RESULT:ok і мають власну причину.
cc_no_work_guard(){
  DIR=${1:?run-dir}; BACKEND=${2:-claude}
  tail -40 "$DIR/out.log" 2>/dev/null | grep -aqE "RESULT:[[:space:]]*\**[[:space:]]*ok" || return 1
  OUT=$(cc_out_tokens "$DIR" "$BACKEND")
  CHANGED=$(cc_changed_value "$DIR")
  TRIP=0
  # out-токени невідомі (жодне джерело) -> не карати за них, лише CHANGED-
  # перевірка нижче; підтверджений <300 -> це і є "нуль роботи".
  if [ -n "$OUT" ]; then
    case "$OUT" in *[!0-9]*) OUT=0 ;; esac
    [ "$OUT" -lt 300 ] && TRIP=1
  fi
  [ -z "$CHANGED" ] && TRIP=1
  if [ "$TRIP" = "1" ]; then
    {
      echo "NOTES: no-work guard: out=${OUT:-н/д}"
      echo "RESULT: fail"
    } >> "$DIR/out.log"
    return 0
  fi
  return 1
}
