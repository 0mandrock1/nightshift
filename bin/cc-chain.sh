#!/bin/sh
# Послідовний ланцюг Claude Code-ранів в ОДНІЙ робочій копії.
# Рани НЕ незалежні: кожен наступний продовжує гілку попереднього, тому вони
# йдуть строго один за одним. Ланцюг спиняється на першому рані без "RESULT: ok".
#
#   sh cc-chain.sh <cwd> <plan-file> [tag]
#
# Формат plan-файлу, по рядку на ран:   slug|style|/abs/path/task.md|model|backend
#   style: ponytail | caveman | none | (порожньо/auto/будь-що інше =
#          авто-призначення π-цифрою за наскрізним індексом — рішення 24.08,
#          model-router-runfile/output-style-tracking; призначає вузол, не чат)
#   model: sonnet|opus|haiku (claude) або gpt-6-luna|gpt-6-sol|gpt-6-astra (codex);
#          порожньо -> sonnet для claude, gpt-6-luna для codex
#   backend (5-те поле, опційно): claude|codex — перекриває CC_BACKEND для
#          цього конкретного рядка плану; порожньо -> CC_BACKEND -> claude
# У task.md плейсхолдер {RUN_ID} підставляється реальним id рану.
#
# ENV: CC_RUNS  (дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs) — тека СТАНУ (run-dirs, локи,
#               .style-index, .pi-digits, лог-файли ланцюга); експортується
#               для дочірніх процесів (cc-run.sh тощо)
#      CC_BACKEND  (дефолт claude) — claude|codex, бекенд для рядків плану без
#               власного 5-го поля; codex-гілка спавнить `codex exec`
#               (мапінг моделі/сесія-лімет/RESULT-парсинг — той самий підхід,
#               що й у cc-run.sh, без делегування туди — ланцюг сам робить
#               git checkout/auto-commit навколо спавну)
#      CC_CODEX_BIN  (дефолт codex) — бінарник Codex CLI
#      CC_CODEX_SANDBOX  (дефолт workspace-write) — codex -s
#      CC_EXTRA_PATH  (дефолт порожньо) — префікс до PATH ПЕРЕД спавном claude
#               (на вузлах, де claude стоїть поза PATH неінтерактивного sh)
#
# Коди виходу: 0 пройшло все | 2 ран впав | 3 session limit ("прийди пізніше", claude чи codex-квота) | 4 конфлікт ізоляції (CWD чи plan вже зайнятий іншим ланцюгом) / ambiguous (RESULT відсутній при чистому exit) | 5 гейт тижневого бюджету / тижневий лок | 6 гард дорогої моделі
set -u

[ -n "${CC_EXTRA_PATH:-}" ] && PATH="$CC_EXTRA_PATH:$PATH"
export PATH
CC_CLAUDE_BIN=${CC_CLAUDE_BIN:-claude}
CC_BACKEND=${CC_BACKEND:-claude}

BIN=$(dirname "$(readlink -f "$0")")
# NODE: дефолт $(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs — резолвиться в /root/ops/cc-runs на VPS
# (root), у ~/ops/cc-runs на десктопі. Раніше desktop-копія мовчки писала
# у VPS-шлях (хардкод /root/ops/cc-runs) — це і був задокументований баг.
CC_RUNS=${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}
export CC_RUNS
RUNS=$CC_RUNS
# shellcheck source=cc-util-lib.sh
[ -f "$BIN/cc-util-lib.sh" ] && . "$BIN/cc-util-lib.sh"

# Обгортка cc-telemetry.sh, що прокидає estimator-v2 змінні (UTIL5H_BEFORE/
# CONCURRENT_N/TASK_KIND виставляє do_run() ДО спавну, UTIL5H_AFTER — ПІСЛЯ,
# усі як глобальні змінні процесу; окремих аргументів не потребує).
chain_telemetry(){
  [ -f "$BIN/cc-telemetry.sh" ] || return 0
  CC_UTIL5H_BEFORE="${UTIL5H_BEFORE:-}" CC_UTIL5H_AFTER="${UTIL5H_AFTER:-}" \
  CC_UTIL7D_BEFORE="${UTIL7D_BEFORE:-}" CC_UTIL7D_AFTER="${UTIL7D_AFTER:-}" \
  CC_CONCURRENT="${CONCURRENT_N:-}" CC_TASK_KIND="${TASK_KIND:-}" \
    sh "$BIN/cc-telemetry.sh" "$1" "${2:-run}" >/dev/null 2>&1
}

# --- Тижневий лок (крон cc-week-guard.sh) ---
# Присутній .week-locked -> тижневого бюджету менше порогу, cc-рани на вузлі
# заглушено до скидання тижня. Дешева перевірка (без node/jq); знімає лок крон.
WEEK_LOCK=${CC_WEEK_LOCK:-$RUNS/.week-locked}
if [ -f "$WEEK_LOCK" ]; then
  echo "ВІДМОВА: тижневий лок активний ($WEEK_LOCK) — cc-рани заглушено до скидання тижня" >&2
  exit 5
fi
CWD=${1:?cwd}; PLAN=${2:?plan}; TAG=${3:-chain}
STAMP=$(date +%Y%m%d-%H%M)
CHAIN=$RUNS/$TAG-$STAMP.log
TOOLS=${CC_TOOLS:-"Bash Edit Write Read Glob Grep"}

# --- Ізоляція: жоден інший ланцюг не має ділити CWD чи plan-файл одночасно ---
# Порушення (15.08): два cc-chain.sh на спільному plan-файлі в одній робочій
# копії виконали два рани двічі; другий прохід закомітив ті самі SHA що й
# перший (~73k out-токенів у нуль дифу). Тримається на mkdir-лок, не на дисципліні.
# ПРИМІТКА: `exec N>file` + `flock -n N` НЕ використовувати на цьому вузлі —
# перевірено вручну (`exec 200>/tmp/test.lock` валить "exec: 200: not found"
# у поточному /bin/sh на цій машині/транспорті). `flock -n LOCKFILE -c '...'`
# командною формою працює нормально, але mkdir атомарний і не залежить від
# flock узагалі — обрано його як найпростіший портативний варіант.
CWD_ABS=$(cd "$CWD" 2>/dev/null && pwd) || { echo "cwd не існує: $CWD" >&2; exit 1; }
PLAN_ABS=$(readlink -f "$PLAN" 2>/dev/null) || { echo "plan не існує: $PLAN" >&2; exit 1; }
LOCK_CWD="$RUNS/.lock-cwd-$(printf '%s' "$CWD_ABS" | md5sum | cut -c1-16).d"
LOCK_PLAN="$RUNS/.lock-plan-$(printf '%s' "$PLAN_ABS" | md5sum | cut -c1-16).d"

# 09.09: `pkill -9` пропускає `trap EXIT`, лок-тека переживає процес, і всі
# наступні спроби того самого ланцюга падають exit 4 назавжди, хоча нічого не
# працює. Замість голого mkdir — тримати PID власника в локу й перевіряти, чи
# він живий, перш ніж визнавати лок реальним.
acquire_lock(){
  d=$1; desc=$2
  if mkdir "$d" 2>/dev/null; then
    echo "$$" > "$d/pid"; return 0
  fi
  HOLDER=$(cat "$d/pid" 2>/dev/null)
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    echo "ВІДМОВА: інший ланцюг вже працює ($desc, lock $d, pid $HOLDER)" >&2
    return 1
  fi
  # Власник мертвий (або pid-файл відсутній через гонку старого коду) —
  # лок протух, забрати його собі.
  MSG="[$(date -u +%H:%M:%S)] лок $d протух (holder ${HOLDER:-?} не живий) — прибрано автоматично"
  rm -rf "$d" 2>/dev/null
  if mkdir "$d" 2>/dev/null; then
    echo "$$" > "$d/pid"
    echo "$MSG" >&2
    echo "$MSG" >> "$CHAIN" 2>/dev/null
    return 0
  fi
  echo "ВІДМОВА: інший ланцюг вже працює ($desc, lock $d)" >&2
  return 1
}
acquire_lock "$LOCK_CWD" "$CWD_ABS" || exit 4
acquire_lock "$LOCK_PLAN" "$PLAN_ABS" || { rm -rf "$LOCK_CWD" 2>/dev/null; exit 4; }
trap 'rm -rf "$LOCK_CWD" "$LOCK_PLAN" 2>/dev/null' EXIT

log(){ echo "[$(date -u +%H:%M:%S)] $*" >> "$CHAIN"; }
# Best-effort Telegram-нотифікація; ніколи не валить ланцюг і не чіпає exit-коди.
# notify — afterflight (ok/fail/session/ланцюг), зі звуком, однорядковий телеграф.
# notify_silent — preflight (старт, <pre>-таблиця), без звуку (disable_notification).
NOTIFY=${CC_NOTIFY:-$BIN/cc-notify.sh}
notify(){ [ -f "$NOTIFY" ] || return 0; sh "$NOTIFY" "$*" >/dev/null 2>&1 || true; }
notify_silent(){ [ -f "$NOTIFY" ] || return 0; sh "$NOTIFY" "$1" silent >/dev/null 2>&1 || true; }
PASSED=0

# --- Протокол аромату (рішення 24.08) ---
# Порожнє/auto/будь-яке значення style, відмінне від трьох літералів нижче,
# призначається π-цифрою за наскрізним індексом — лічильник .style-index
# СПІЛЬНИЙ для всіх обгорток (лежить поза цим скриптом, у $RUNS), не
# скидається щобатчу: короткі батчі інакше систематично недобирають
# контрольну групу. digit mod 3 -> 0 caveman / 1 ponytail / 2 none.
# Явний style (caveman|ponytail|none) у plan-файлі — ручний override,
# лічильник НЕ чіпає. Призначення робить вузол, не чат-шар.
STYLE_DIGITS_FILE="$RUNS/.pi-digits"
STYLE_INDEX_FILE="$RUNS/.style-index"
STYLE_LOCK="$RUNS/.lock-style-index.d"
resolve_style(){
  in=$1
  case "$in" in
    caveman|ponytail|none) echo "$in"; return ;;
  esac
  n=0
  while ! mkdir "$STYLE_LOCK" 2>/dev/null; do
    n=$((n+1)); [ "$n" -gt 50 ] && break
    sleep 0.1
  done
  DIGITS=$(cat "$STYLE_DIGITS_FILE" 2>/dev/null)
  [ -n "$DIGITS" ] || DIGITS=31415926535897932384626433832795028841971693993751058209749445923078
  IDX=$(cat "$STYLE_INDEX_FILE" 2>/dev/null)
  case "$IDX" in ''|*[!0-9]*) IDX=0 ;; esac
  LEN=${#DIGITS}
  POS=$((IDX % LEN + 1))
  DIGIT=$(printf '%s' "$DIGITS" | cut -c"$POS")
  echo $((IDX + 1)) > "$STYLE_INDEX_FILE"
  rmdir "$STYLE_LOCK" 2>/dev/null
  case $((DIGIT % 3)) in
    0) echo caveman ;;
    1) echo ponytail ;;
    *) echo none ;;
  esac
}

# Sync-only: дописати обов'язкову секцію, якщо автор task.md її забув.
# Env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 фон НЕ забороняє (22.09, R4/R5).
sync_only(){
  grep -q '^## Sync-only' "$1" 2>/dev/null && return 0
  cat >> "$1" <<'SYNCONLY'

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
}
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

do_run(){
  slug=$1; style=$2; task=$3; model=${4:-}; backend_raw=${5:-}
  backend=$backend_raw; [ -n "$backend" ] || backend=$CC_BACKEND
  case "$backend" in
    claude|codex) : ;;
    *) log "$slug: невідомий backend '$backend' (очікую claude|codex) — ланцюг спинено"; exit 1 ;;
  esac
  if [ "$backend" = codex ]; then
    # Мапінг claude-стилю моделі -> codex slug (той самий, що cc-run.sh), щоб
    # plan-рядки з opus/sonnet/haiku відпрацьовували без правок на codex.
    case "$model" in
      "")     CODEXMODEL=gpt-6-luna ;;
      opus)   CODEXMODEL=gpt-6-sol ;;
      sonnet) CODEXMODEL=gpt-6-luna ;;
      haiku)  CODEXMODEL=gpt-6-luna ;;
      gpt-*)  CODEXMODEL=$model ;;
      *)
        log "$slug: невідома модель для codex-бекенда: '$model' (очікую opus|sonnet|haiku|порожньо|gpt-*) — ланцюг спинено"
        exit 2
        ;;
    esac
    case "$CODEXMODEL" in
      gpt-6-sol|gpt-6-astra) GATEMODEL=opus ;;
      *) GATEMODEL=$model ;;
    esac
  else
    # 11.09: порожнє поле мало давати sonnet-дефолт (cc-preferences 27.08), а
    # мовчки йшло в CLI-дефолт (opus), обходячи opus-gate. R1 thumbfeed заплатив
    # $26.91 переплати через це. Fail-closed: порожньо -> sonnet.
    [ -n "$model" ] || model=sonnet
    MODELARG=""; [ -n "$model" ] && MODELARG="--model $model"
    GATEMODEL=$model
  fi
  # Гард дорогої моделі — на КОЖЕН крок ланцюга окремо: план може змішувати
  # sonnet і opus по рядках, тож перевірка мусить бути тут, а не на старті.
  if [ -f "$BIN/cc-opus-gate.sh" ]; then
    sh "$BIN/cc-opus-gate.sh" "$GATEMODEL" "$slug" || { log "$slug: opus-gate ВІДМОВА — ланцюг спинено"; exit 6; }
  fi
  id="$slug-$STAMP"; d="$RUNS/$id"; mkdir -p "$d"
  cd "$CWD" || exit 1
  git rev-parse HEAD > "$d/base_sha"
  git checkout -q -b "cc/$id" || { log "$id: не змогло створити гілку"; exit 1; }
  sed "s|{RUN_ID}|$id|g" "$task" > "$d/task.md"
  sync_only "$d/task.md"
  # Гарантія RESULT: той самий контракт, що й у cc-run.sh — дописуємо в кінець
  # ПРОМПТУ, бо модель надійніше слухає останній рядок.
  cat >> "$d/task.md" <<'RESULTCONTRACT'

---
КОНТРАКТ ВИВОДУ (обов'язково, незалежно від стилю відповіді вище): передостаннім рядком — "CHANGED: <файли/зміни через кому>", або "CHANGED: none", якщо реальних змін не було (порожньо чи відсутній рядок = гард нуль-роботи позначить ран як fail). Останній рядок усієї відповіді — рівно "RESULT: ok" або "RESULT: fail", без зірочок, без тексту після нього. Людський підсумок вище — ОК, але ці два рядки йдуть строго в кінці, у цьому порядку.
RESULTCONTRACT
  # Estimator v2: util5h/7d ДО спавну + concurrency на старті + task_kind
  # (best-effort, порожньо -> NULL у swarm.runs). Той самий снапшот, що
  # cc-run.sh, спільна функція з cc-util-lib.sh.
  TASK_KIND=$(command -v cc_task_kind >/dev/null 2>&1 && cc_task_kind "$id" || echo "${id%%-*}")
  CONCURRENT_N=$(command -v cc_concurrent_others >/dev/null 2>&1 && cc_concurrent_others || echo "")
  UTIL_BEFORE=$(command -v cc_util_snapshot >/dev/null 2>&1 && cc_util_snapshot || echo "  ")
  UTIL5H_BEFORE=$(echo "$UTIL_BEFORE" | cut -d' ' -f1)
  UTIL7D_BEFORE=$(echo "$UTIL_BEFORE" | cut -d' ' -f2)
  log "$id старт (backend=$backend, style=$style, base=$(cut -c1-7 < $d/base_sha))"
  # CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0: без цього headless-сесія може
  # вийти по стелі очікування фонової задачі (Task/background bash),
  # обірвавши сесію ДО друку RESULT: — ран падає з реальною роботою
  # закомiченою, але формально FAIL (model-router-runfile SKILL.md
  # §Fan-out). Спрацювало 24.08 на tv2-time-preact: фоновий unit-test
  # batch, візуал-чек зелений, RESULT: так і не надрукувався.
  # RUN_TIMEOUT_S: жорсткий backstop поверх CEILING_MS вище — той лише робить
  # очікування видимим (один рядок у out.log), але сам по собі не обмежує
  # його в часі. Спрацювало 24.08 на tv2-rail: 26 хв, один рядок логу
  # "Waiting for background task notifications", реальна робота (228 рядків
  # rail.js) є, RESULT: так і не надрукувався. timeout не має нової семантики
  # для не-session-limit шляху: убитий процес так само не лишає "session
  # limit" у out.log і так само падає в гілку auto-commit -> FAIL нижче,
  # просто за фіксований час, а не за весь залишок вікна.
  RUN_TIMEOUT_S=${CC_RUN_TIMEOUT_S:-2700}
  if [ "$backend" = codex ]; then
    # Codex CLI: немає --settings/outputStyle/--allowedTools, аромат уже
    # впаяний у task.md. RESULT-контракт codex пише у -o файл
    # (last-message.txt), не в stdout — дописуємо в кінець out.log, щоб
    # RESULT/NOTES-парсинг нижче (спільний з claude-гілкою) працював без змін.
    CC_CODEX_BIN=${CC_CODEX_BIN:-codex}
    CC_CODEX_SANDBOX=${CC_CODEX_SANDBOX:-workspace-write}
    timeout "$RUN_TIMEOUT_S" "$CC_CODEX_BIN" exec -m "$CODEXMODEL" \
      -s "$CC_CODEX_SANDBOX" --skip-git-repo-check --add-dir "$d" \
      -c model_auto_compact_token_limit=270000 \
      -C "$CWD" --json -o "$d/last-message.txt" "$(cat "$d/task.md")" \
      < /dev/null > "$d/events.jsonl" 2> "$d/out.log"
    CLAUDE_EXIT=$?
    [ -f "$d/last-message.txt" ] && cat "$d/last-message.txt" >> "$d/out.log"
    # turn.failed / квота / rate-limit в events.jsonl -> той самий шлях
    # "session limit" нижче, що вже ловить claude-гілку (exit 3).
    # Лише error реального turn.failed (як у cc-run.sh). НЕ grep по всьому
    # events.jsonl: task/command/agent text легітимно містить rate-limit/quota
    # (напр. ratelimit.py, "429 rate_limited") і давав хибний exit 3 після
    # RESULT: ok (02.10, tt2-e2e4 і nsfix).
    if [ "$CLAUDE_EXIT" != 124 ] && [ -f "$d/events.jsonl" ] && command -v jq >/dev/null 2>&1 \
      && jq -se 'any(.[]; .type=="turn.failed" and (((.error.message // .error // "") | tostring) | test("rate.?limit|quota|usage_limit|session limit"; "i")))' "$d/events.jsonl" >/dev/null 2>&1; then
      echo "session limit" >> "$d/out.log"
    fi
  elif [ "$style" = "none" ]; then
    timeout "$RUN_TIMEOUT_S" env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$CC_CLAUDE_BIN" -p "$(cat $d/task.md)" $MODELARG --permission-mode acceptEdits --allowedTools "$TOOLS" < /dev/null > "$d/out.log" 2>&1
    CLAUDE_EXIT=$?
  else
    timeout "$RUN_TIMEOUT_S" env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 "$CC_CLAUDE_BIN" -p "$(cat $d/task.md)" $MODELARG --permission-mode acceptEdits --allowedTools "$TOOLS" --settings "{\"outputStyle\":\"$style\"}" < /dev/null > "$d/out.log" 2>&1
    CLAUDE_EXIT=$?
  fi
  [ "$CLAUDE_EXIT" = 124 ] && log "$id: TIMEOUT — вбито по ${RUN_TIMEOUT_S}s, перевіряю чи є реальна робота нижче"
  log "$(sh "$BIN/run-usage.sh" "$d" 2>&1 | tail -1)"
  [ -f "$BIN/cc-cost.sh" ] && log "$(sh "$BIN/cc-cost.sh" "$d" 2>/dev/null | tail -1)"
  # Гард «нуль роботи» (estimator v2, 27.09): RESULT: ok з <300 out-токенів
  # або без непорожнього CHANGED: — переписує хвіст out.log на RESULT: fail
  # ДО перевірки нижче, тому ok/fail-гілка сама бачить оновлений стан. Не
  # застосовується до session-limit (той шлях не має RESULT: ok у хвості).
  command -v cc_no_work_guard >/dev/null 2>&1 && cc_no_work_guard "$d" "$backend"
  # Estimator v2: util5h/7d ПІСЛЯ рану — до telemetry, разом з "до"-значеннями.
  # Рахується ОДИН раз тут (до session-limit гілки), щоб той самий знімок
  # ішов у telemetry незалежно від того, якою гілкою вийде цей крок.
  UTIL_AFTER=$(command -v cc_util_snapshot >/dev/null 2>&1 && cc_util_snapshot || echo "  ")
  UTIL5H_AFTER=$(echo "$UTIL_AFTER" | cut -d' ' -f1)
  UTIL7D_AFTER=$(echo "$UTIL_AFTER" | cut -d' ' -f2)
  if grep -aq "session limit" "$d/out.log"; then
    log "$id: SESSION LIMIT — ланцюг спинено, це не провал задачі"
    echo 3 > "$d/exit_code"
    chain_telemetry "$d" run
    notify "⛔ $TAG · session limit · <code>$id</code> · $PASSED ok до цього · exit 3"; exit 3
  fi
  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -qm "chore($slug): auto-commit run output" && log "$id: авто-коміт незакоміченого"
  fi
  if tail -40 "$d/out.log" | grep -aqE "RESULT:[[:space:]]*\**[[:space:]]*ok"; then
    log "$id: ok ($(git rev-parse --short HEAD))"
    echo 0 > "$d/exit_code"
    chain_telemetry "$d" run
    PASSED=$((PASSED+1)); notify "✅ $TAG · run ok · <code>$(git rev-parse --short HEAD)</code> · пройдено $PASSED"
  else
    if [ "$CLAUDE_EXIT" = 0 ]; then
      # claude завершився чисто, але RESULT: ok не знайдено — розрізняємо
      # "агент явно сказав fail" від "агент забув Report-блок" (той самий
      # 4-станий матчер, що й у cc-run.sh). AMBIGUOUS зупиняє ланцюг для
      # ручної перевірки, а не позначає наосліп як FAIL.
      if tail -40 "$d/out.log" | grep -aqE "RESULT:[[:space:]]*\**[[:space:]]*fail"; then
        RMSG="RESULT: fail"
      else
        R=$(fail_reason "$d"); echo "$R" > "$d/fail_reason"
        RMSG="RESULT відсутній, $R"
      fi
      log "$id: AMBIGUOUS — claude завершився чисто, $RMSG — ланцюг спинено для ручної перевірки, гілка лишена"
      echo 4 > "$d/exit_code"
      chain_telemetry "$d" run
      notify "⚠️ $TAG · ambiguous · <code>$id</code> · $PASSED ok до цього · exit 4 · $RMSG, перевір вручну · гілку лишено"; exit 4
    fi
    R=OK-FAIL
    tail -40 "$d/out.log" | grep -aqE "RESULT:[[:space:]]*\**[[:space:]]*fail" || R=$(fail_reason "$d")
    [ "$CLAUDE_EXIT" = 124 ] && R="$R+TIMEOUT"
    echo "$R" > "$d/fail_reason"
    log "$id: FAIL [$R] — ланцюг спинено, гілка лишена як є для розбору"
    echo 2 > "$d/exit_code"
    chain_telemetry "$d" run
    notify "❌ $TAG · run fail [$R] · <code>$id</code> · $PASSED ok до цього · exit 2 · гілку лишено"; exit 2
  fi
}

log "ланцюг стартував від $(git -C "$CWD" rev-parse --abbrev-ref HEAD)"
# Пре-фліт оцінка по першому кроку плану — грубий проксі на весь ланцюг (best-effort).
if [ -f "$BIN/cc-estimate.sh" ]; then
  FIRST_LINE=$(grep -vE '^#|^$' "$PLAN" | head -1)
  FIRST_SLUG=$(echo "$FIRST_LINE" | cut -d'|' -f1)
  FIRST_TASK=$(echo "$FIRST_LINE" | cut -d'|' -f3)
  FIRST_MODEL=$(echo "$FIRST_LINE" | cut -d'|' -f4)
  FIRST_BACKEND=$(echo "$FIRST_LINE" | cut -d'|' -f5)
  [ -n "$FIRST_BACKEND" ] || FIRST_BACKEND=$CC_BACKEND
  case "$FIRST_BACKEND" in
    claude|codex) : ;;
    *) log "$FIRST_SLUG: невідомий backend '$FIRST_BACKEND' (очікую claude|codex) — ланцюг спинено"; exit 1 ;;
  esac
  MIXED_BACKEND=$(awk -F'|' -v first="$FIRST_BACKEND" -v fallback="$CC_BACKEND" '
    $0 !~ /^#/ && $0 !~ /^$/ { backend=$5; if (backend=="") backend=fallback; if (backend!=first) { print backend; exit } }
  ' "$PLAN")
  [ -z "$MIXED_BACKEND" ] || log "змішаний план: preflight для першого backend=$FIRST_BACKEND; далі є backend=$MIXED_BACKEND"
  [ -n "$FIRST_MODEL" ] || FIRST_MODEL=sonnet
  # task_kind для estimator v2 — той самий алгоритм, що cc_task_kind()/do_run:
  # префікс slug-у до першого "-" (slug -> id="$slug-$STAMP"), а не basename
  # task.md (майже завжди буквально "task.md" -> KIND=task, повз бакет model×kind).
  FIRST_KIND=${FIRST_SLUG%%-*}
  N_STEPS=$(grep -vcE '^#|^$' "$PLAN")
  if [ -n "$FIRST_TASK" ] && [ -f "$FIRST_TASK" ]; then
    PREFLIGHT=$(sh "$BIN/cc-estimate.sh" --task "$FIRST_TASK" --model "$FIRST_MODEL" --lanes "$N_STEPS" --maxpar 1 --kind "$FIRST_KIND" --backend "$FIRST_BACKEND" 2>/dev/null)
    if [ -n "$PREFLIGHT" ]; then
      log "preflight: backend=$FIRST_BACKEND"
      log "$PREFLIGHT"
      # Telegram отримує компактний HTML-блок; повний PREFLIGHT (з VARS) лишається в лозі ланцюга.
      PF_HTML=$(sh "$BIN/cc-estimate.sh" --task "$FIRST_TASK" --model "$FIRST_MODEL" --lanes "$N_STEPS" --maxpar 1 --kind "$FIRST_KIND" --backend "$FIRST_BACKEND" --compact-html 2>/dev/null)
      # --- Ризик-оцінка старту (гучна нотифікація замість тихої) ---
      # RISK=1, якщо повний PREFLIGHT містить маркер "PREFLIGHT: ⚠ дорого"
      # АБО реальне поточне завантаження 5h-вікна вище порогу CC_RISK_5H_MIN.
      RISK=0
      RISK_REASON=""
      case "$PREFLIGHT" in
        *"PREFLIGHT: ⚠ дорого") RISK=1; RISK_REASON="дорого за тижневим кепом" ;;
      esac
      CC_RISK_5H_MIN=${CC_RISK_5H_MIN:-70}
      RISK_USAGE_CLI=${CC_USAGE_CLI:-/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js}
      UTIL5H=""
      if [ "$FIRST_BACKEND" = "codex" ] && [ -x "$BIN/cc-codex-usage.sh" ]; then
        UTIL5H=$(sh "$BIN/cc-codex-usage.sh" --tuple 2>/dev/null | cut -d' ' -f1)
      elif command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$RISK_USAGE_CLI" ]; then
        UTIL5H=$(node "$RISK_USAGE_CLI" --ratelimit-json 2>/dev/null | jq -r '.util5h // empty' 2>/dev/null)
      fi
      if [ -n "$UTIL5H" ]; then
        case "$UTIL5H" in
          ''|*[!0-9.]*) : ;;
          *)
            UTIL5H_PCT=$(awk -v u="$UTIL5H" 'BEGIN{printf "%.1f",u*100}')
            if awk -v p="$UTIL5H_PCT" -v m="$CC_RISK_5H_MIN" 'BEGIN{exit !(p>=m)}'; then
              RISK=1
              if [ -n "$RISK_REASON" ]; then
                RISK_REASON="$RISK_REASON; 5h-вікно ${UTIL5H_PCT}% >= ${CC_RISK_5H_MIN}%"
              else
                RISK_REASON="5h-вікно ${UTIL5H_PCT}% >= ${CC_RISK_5H_MIN}%"
              fi
            fi
            ;;
        esac
      fi
      if [ "$RISK" = 1 ]; then
        log "риск-оцінка старту: RISK=$RISK ($RISK_REASON)"
      else
        log "риск-оцінка старту: RISK=0"
      fi
      if [ -n "$PF_HTML" ]; then
        if [ "$RISK" = 1 ]; then
          notify "⚠ РИЗИКОВИЙ СТАРТ · $RISK_REASON
<b>$TAG · старт ланцюга · $N_STEPS кроків · backend=$FIRST_BACKEND</b>
$PF_HTML"
        else
          notify_silent "<b>$TAG · старт ланцюга · $N_STEPS кроків · backend=$FIRST_BACKEND</b>
$PF_HTML"
        fi
      else
        if [ "$RISK" = 1 ]; then
          notify "⚠ РИЗИКОВИЙ СТАРТ · $RISK_REASON
$TAG: старт ланцюга ($N_STEPS кроків, backend=$FIRST_BACKEND) | $PREFLIGHT"
        else
          notify_silent "$TAG: старт ланцюга ($N_STEPS кроків, backend=$FIRST_BACKEND) | $PREFLIGHT"
        fi
      fi
    fi
  fi
fi
# --- Гейт тижневого бюджету (25.08) ---
# Реальний % — з того самого офіційного джерела, що й бари /usage
# (usage-cli.js --ratelimit-json .util7d), не з оцінки cc-estimate.
# Ланцюг ВІДМОВЛЯЄТЬСЯ стартувати, якщо тижня лишилось менше порогу —
# структурна відсічка, яку не переговориш. Поріг CC_WEEK_MIN_LEFT (%, дефолт 5;
# 0 = вимкнути). Число недоступне -> fail-open (backstop лишається exit 3).
GATE_USAGE_CLI=${CC_USAGE_CLI:-/root/projects/tg_bots/mandrock0_cc_bot/usage-cli.js}
WEEK_MIN_LEFT=${CC_WEEK_MIN_LEFT:-5}
if [ "${WEEK_MIN_LEFT}" != 0 ] && command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$GATE_USAGE_CLI" ]; then
  U7=$(node "$GATE_USAGE_CLI" --ratelimit-json 2>/dev/null | jq -r '.util7d // empty' 2>/dev/null)
  case "$U7" in
    ''|*[!0-9.]*) log "гейт тижня: util7d недоступний — fail-open, старт дозволено" ;;
    *)
      LEFT=$(awk -v u="$U7" 'BEGIN{printf "%.1f",(1-u)*100}')
      if awk -v l="$LEFT" -v m="$WEEK_MIN_LEFT" 'BEGIN{exit !(l<m)}'; then
        log "ГЕЙТ ТИЖНЯ: лишилось ${LEFT}% < ${WEEK_MIN_LEFT}% — ланцюг не стартував (exit 5)"
        notify "🚧 $TAG · гейт тижня · лишилось ${LEFT}% < ${WEEK_MIN_LEFT}% · не стартував · exit 5"
        exit 5
      fi
      log "гейт тижня: лишилось ${LEFT}% >= ${WEEK_MIN_LEFT}% — старт дозволено"
      ;;
  esac
fi
while IFS='|' read -r slug style_raw task model backend_raw; do
  [ -n "${slug:-}" ] || continue
  case "$slug" in \#*) continue ;; esac
  style=$(resolve_style "$style_raw")
  [ "$style" = "$style_raw" ] || log "$slug: аромат авто-призначено π-цифрою -> $style"
  do_run "$slug" "$style" "$task" "${model:-}" "${backend_raw:-}"
done < "$PLAN"
log "ланцюг пройшов повністю, гілка $(git -C "$CWD" rev-parse --abbrev-ref HEAD)"
notify "✅ $TAG · ланцюг пройшов · $PASSED ранів ok · гілка $(git -C "$CWD" rev-parse --abbrev-ref HEAD) · exit 0"
