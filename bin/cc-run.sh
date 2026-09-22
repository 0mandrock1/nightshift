#!/bin/sh
# Обгортка ОДИНОЧНОГО cc-рану: claude -p → витяг RESULT з out.log → нотифікація.
# Ланцюг має свою нотифікацію в cc-chain.sh; це — та сама точка для ранів поза
# ланцюгом, щоб обіцянка «будь-який ран нотифікує» була правдою, а не текстом.
#
#   sh cc-run.sh <run-dir> [style] [model]
#     <run-dir>  тека рану, у якій ВЖЕ лежить task.md
#     style      ponytail | caveman | none (дефолт none = без --settings)
#
# ENV: CC_RUNS   (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs) — тека СТАНУ (run-dirs, локи,
#                логи); експортується для дочірніх процесів
#      CC_TOOLS  (дефолт "Bash Edit Write Read Glob Grep")
#      CC_NOTIFY (дефолт <bin>/cc-notify.sh; нема файлу — нотифікація тихо
#                 пропускається, ран від цього не падає)
#      CC_TAG    (префікс у повідомленні, дефолт "run")
#      CC_CLAUDE_BIN  (дефолт "claude") — назва/шлях бінарника claude CLI
#      CC_EXTRA_PATH  (дефолт порожньо) — префікс до PATH ПЕРЕД спавном; на
#                 вузлах, де `claude` стоїть поза стандартним PATH
#                 неінтерактивного sh (напр. ~/.local/bin на WSL/десктопі)
#
# Коди виходу: 0 ok | 2 fail (нема RESULT: ok) | 3 session limit | 5 тижневий лок | 6 гард дорогої моделі
set -u

# NODE: на деяких вузлах `claude` стоїть поза PATH неінтерактивного sh
# (напр. ~/.local/bin на WSL-десктопі) — префікс лишається порожнім на
# vps/skill, де це не потрібно.
[ -n "${CC_EXTRA_PATH:-}" ] && PATH="$CC_EXTRA_PATH:$PATH"
export PATH
CC_CLAUDE_BIN=${CC_CLAUDE_BIN:-claude}

BIN=$(dirname "$(readlink -f "$0")")
CC_RUNS=${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}
export CC_RUNS

# --- Тижневий лок (крон cc-week-guard.sh) ---
# Присутній .week-locked -> тижневого бюджету менше порогу, cc-рани на вузлі
# заглушено до скидання тижня. Дешева перевірка (без node/jq); знімає лок крон.
WEEK_LOCK=${CC_WEEK_LOCK:-$CC_RUNS/.week-locked}
if [ -f "$WEEK_LOCK" ]; then
  echo "ВІДМОВА: тижневий лок активний ($WEEK_LOCK) — cc-рани заглушено до скидання тижня" >&2
  exit 5
fi

D=${1:?run-dir}; D=${D%/}
STYLE=${2:-none}
MODEL=${3:-}
BACKEND=${4:-claude}
[ -f "$D/task.md" ] || { echo "cc-run: нема $D/task.md" >&2; exit 1; }
# Гарантія RESULT: незалежно від того, чи task.md сам про це попросив і чи
# стиль (ponytail тощо) це перебив людським підсумком — дописуємо контракт
# в кінець ПРОМПТУ (не в середину), бо модель надійніше слухає останній рядок.
grep -q "^КОНТРАКТ ВИВОДУ" "$D/task.md" 2>/dev/null || cat >> "$D/task.md" <<'RESULTCONTRACT'

---
КОНТРАКТ ВИВОДУ (обов'язково, незалежно від стилю відповіді вище): останній рядок усієї відповіді — рівно "RESULT: ok" або "RESULT: fail", без зірочок, без тексту після нього. Людський підсумок вище — ОК, але цей рядок йде строго останнім.
RESULTCONTRACT

# Sync-only: дописати обов'язкову секцію, якщо автор task.md її забув.
# Env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 фон НЕ забороняє (22.09, R4/R5).
grep -q '^## Sync-only' "$D/task.md" 2>/dev/null || cat >> "$D/task.md" <<'SYNCONLY'

## Sync-only
Жодних run_in_background, Monitor, фонових poller-ів, фонових Task-сабагентів,
`&` на команді, результат якої ти потім чекаєш (тест, білд, verify). Виняток —
демон (systemd/setsid) з чекпоінтом: запустив і НЕ чекаєш, двічі міряєш
лічильник прогресу. У `-p`-режимі нема механізму
отримати нотифікацію про завершення фонової задачі: закінчив хід «чекаю
монітор» — сесія виходить без RESULT, робота зараховується як провал.
Чекати можна лише синхронно, в межах одного Bash-виклику, з лімітом:
  i=0; until <перевірка>; do i=$((i+1)); [ $i -ge 10 ] && break; sleep 10; done
Дефолтний timeout Bash-виклику — 120 с: цикл довший за це вбʼється посередині.
Треба довше — явний параметр timeout виклику (до 600000 мс), не фон.
Ліміт вичерпано — це факт для NOTES і RESULT: fail, не привід чекати далі.
Довше ніж ран (години) — не чекати взагалі, а той самий демон з чекпоінтом.
Останній хід сесії — завжди блок Report, ніколи «чекаю».
SYNCONLY

pwd > "$D/cwd" 2>/dev/null || true
ID=$(basename "$D")
TOOLS=${CC_TOOLS:-"Bash Edit Write Read Glob Grep"}
NOTIFY=${CC_NOTIFY:-$BIN/cc-notify.sh}
TAG=${CC_TAG:-run}
MODELARG=""; [ -n "$MODEL" ] && MODELARG="--model $MODEL"
SESSID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
[ -n "$SESSID" ] && echo "$SESSID" > "$D/session_id"
SESSARG=""; [ -n "$SESSID" ] && SESSARG="--session-id $SESSID"

# --- Гард дорогої моделі (cc-opus-gate.sh) ---
# ПЕРЕД спавном: opus без CC_OPUS_REASON не стартує. Ловиться до витрати
# токенів, тому відмова безкоштовна. Код виходу 6 прокидається наверх.
if [ -f "$BIN/cc-opus-gate.sh" ]; then
  sh "$BIN/cc-opus-gate.sh" "$MODEL" "$ID" || exit $?
fi

# Best-effort: нотифікація ніколи не валить ран і не чіпає код виходу.
# notify — afterflight (ok/fail/session), зі звуком, однорядковий телеграф.
# notify_silent — preflight (старт, <pre>-таблиця), без звуку.
notify(){ [ -f "$NOTIFY" ] || return 0; { echo "--- notify $(date -u +%FT%TZ) ---"; sh "$NOTIFY" "$*"; echo "notify rc=$?"; } >>"$D/notify-debug.log" 2>&1 || true; }
notify_silent(){ [ -f "$NOTIFY" ] || return 0; { echo "--- notify_silent $(date -u +%FT%TZ) ---"; sh "$NOTIFY" "$1" silent; echo "notify_silent rc=$?"; } >>"$D/notify-debug.log" 2>&1 || true; }
# Екранування під HTML parse_mode Telegram (див. cc-notify.sh).
esc(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
# Причина провалу без RESULT: фонове очікування чи ні. Код виходу не міняє —
# лише мітка в fail_reason/лог/нотифікацію, щоб статистика не плутала BG-WAIT
# з провалом задачі.
fail_reason(){
  if tail -60 "$1/out.log" 2>/dev/null | grep -aqiE 'background|run_in_background|фонов|монітор|monitor|poller|чекаю'; then
    echo BG-WAIT
  else
    echo NO-RESULT
  fi
}

# Пре-фліт оцінка перед спавном — у лог і в стартову нотифікацію (best-effort).
ESTIMATE_SH="$BIN/cc-estimate.sh"
if [ -f "$ESTIMATE_SH" ] && [ -n "$MODEL" ]; then
  PREFLIGHT=$(sh "$ESTIMATE_SH" --task "$D/task.md" --model "$MODEL" --run-id "$ID" 2>/dev/null)
  if [ -n "$PREFLIGHT" ]; then
    echo "$PREFLIGHT" > "$D/preflight.log"
    # Telegram отримує компактний HTML-блок; повний PREFLIGHT (з VARS) лишається в preflight.log.
    PF_HTML=$(sh "$ESTIMATE_SH" --task "$D/task.md" --model "$MODEL" --compact-html 2>/dev/null)
    if [ -n "$PF_HTML" ]; then
      notify_silent "<b>$TAG · старт</b>
<code>$ID</code>
$PF_HTML"
    else
      notify_silent "$TAG $ID: старт | $PREFLIGHT"
    fi
  fi
fi

if [ "$BACKEND" = "codex" ]; then
  # Codex CLI: немає --settings/outputStyle, аромат уже впаяний у task.md
  # (STYLE:-рядок або нативний settings.json, той самий task.md для обох
  # бекендів). Немає --allowedTools — sandbox workspace-write є еквівалентом
  # acceptEdits (правки лишаються в CWD, без мережі/поза-репо без явного дозволу).
  # --skip-git-repo-check — безкоштовно, коли CWD і так git-репо; рятує коли ні.
  CODEXMODEL=""; [ -n "$MODEL" ] && CODEXMODEL="-m $MODEL"
  codex exec $CODEXMODEL -s workspace-write --skip-git-repo-check \
    -C "$PWD" -o "$D/last-message.txt" "$(cat "$D/task.md")" \
    < /dev/null > "$D/out.log" 2>&1
elif [ "$STYLE" = "none" ]; then
  # RUN_TIMEOUT_S: жорсткий backstop поверх CEILING_MS вище — той лише робить
  # очікування видимим (один рядок у out.log), але сам по собі не обмежує
  # його в часі (як у cc-chain.sh).
  RUN_TIMEOUT_S=${CC_RUN_TIMEOUT_S:-2700}
  timeout "$RUN_TIMEOUT_S" env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$CC_CLAUDE_BIN" -p "$(cat "$D/task.md")" $MODELARG $SESSARG --permission-mode acceptEdits \
    --allowedTools "$TOOLS" < /dev/null > "$D/out.log" 2>&1
else
  RUN_TIMEOUT_S=${CC_RUN_TIMEOUT_S:-2700}
  timeout "$RUN_TIMEOUT_S" env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$CC_CLAUDE_BIN" -p "$(cat "$D/task.md")" $MODELARG $SESSARG --permission-mode acceptEdits \
    --allowedTools "$TOOLS" --settings "{\"outputStyle\":\"$STYLE\"}" < /dev/null > "$D/out.log" 2>&1
fi
RC=$?
echo "$RC" > "$D/exit_code"

# Юзедж рахуємо, якщо скрипт є на вузлі; його відсутність — не помилка рану.
[ -f "$BIN/run-usage.sh" ] && sh "$BIN/run-usage.sh" "$D" > "$D/usage.txt" 2>&1

# Вартість рану + sonnet-еквівалент — у cost.log і telemetry.log (best-effort).
[ -f "$BIN/cc-cost.sh" ] && sh "$BIN/cc-cost.sh" "$D" >/dev/null 2>&1

# Телеметрія в swarm.runs (Postgres) — best-effort, ніколи не чіпає код виходу.
# CC_TELEMETRY_KIND/CC_PARENT_RUN_ID виставляє викликач (cc-swarm.sh для лейнів/fan-in);
# дефолт — одиночний ран поза роєм/ланцюгом.
[ -f "$BIN/cc-telemetry.sh" ] && sh "$BIN/cc-telemetry.sh" "$D" "${CC_TELEMETRY_KIND:-run}" "${CC_PARENT_RUN_ID:-}" >/dev/null 2>&1

# session limit — «прийди пізніше», окремий код, не провал задачі (як у ланцюзі).
if grep -aq "session limit" "$D/out.log" 2>/dev/null; then
  notify "⛔ $TAG · session limit · <code>$ID</code> · ран не доїхав, прийди пізніше · exit 3"
  exit 3
fi

# Той самий матчер, що й у cc-chain.sh: RESULT може приїхати обгорнутим у **.
LINE=$(tail -40 "$D/out.log" | grep -aE "RESULT:[[:space:]]*\**[[:space:]]*(ok|fail)" | tail -1)
NOTES=$(tail -40 "$D/out.log" | grep -aE "^[[:space:]]*\**[[:space:]]*NOTES:" | tail -1 | cut -c1-200 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)

if printf '%s' "$LINE" | grep -aqE "RESULT:[[:space:]]*\**[[:space:]]*ok"; then
  notify "✅ $TAG · ok · <code>$ID</code>${NOTES:+ · $(esc "$NOTES")}"
  exit 0
fi

if [ -n "$LINE" ]; then
  notify "❌ $TAG · fail · <code>$ID</code> · exit $RC · RESULT: fail${NOTES:+ · $(esc "$NOTES")}"
  exit 2
fi

# Нема рядка RESULT. claude завершився чисто (RC=0) — це формат-провал агента
# (забув Report-блок), не провал задачі; не позначати як fail наосліп.
if [ "$RC" = 0 ]; then
  R=$(fail_reason "$D"); echo "$R" > "$D/fail_reason"
  notify "⚠️ $TAG · ambiguous · <code>$ID</code> · exit 0, нема RESULT ($R) — перевір out.log вручну${NOTES:+ · $(esc "$NOTES")}"
  exit 4
fi
R=$(fail_reason "$D"); echo "$R" > "$D/fail_reason"
WHY="нема рядка RESULT у хвості логу, $R"
[ "$RC" = 124 ] && WHY="$WHY, timeout ${RUN_TIMEOUT_S:-2700}s"
notify "❌ $TAG · fail · <code>$ID</code> · exit $RC · $WHY${NOTES:+ · $(esc "$NOTES")}"
exit 2
