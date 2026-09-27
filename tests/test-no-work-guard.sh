#!/bin/sh
# Гард «нуль роботи» (estimator v2, 30.09): RESULT: ok з out-токенів < 300 —
# реальний інцидент 27.09 (два рани 29/78 out-токенів звітували ok). Кейси:
#   (a) out.log з ~29 out-токенами у usage.json -> RESULT переписано на fail, exit 2
#   (b) нормальний ран (>=300 out, CHANGED непорожній) -> RESULT: ok лишається, exit 0
#   (c) RESULT: ok, out>=300, але CHANGED відсутній -> гард все одно ловить
#   (d) usage.json відсутній зовсім (невідомо) -> НЕ карати за токени,
#       лише за CHANGED (уникнути хибного позитиву на власній діагностичній
#       прогалині run-usage.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Самодостатній і при прямому запуску (не лише через run-all.sh): стаб
# ratelimit-джерела, щоб cc_util_snapshot (before/after у cc-run.sh) не бив
# по реальному usage-cli.js/claude -p при кожному з 4 кейсів нижче.
CC_USAGE_CLI=${CC_USAGE_CLI:-"$HERE/fixtures/usage-cli-stub.js"}
export CC_USAGE_CLI

CC_RUNS="$TMP/runs"
mkdir -p "$CC_RUNS"
CLAUDE_STUB="$TMP/claude.sh"

run_case(){
  ID=$1; OUT_LOG_BODY=$2; USAGE_OUT=$3
  D="$CC_RUNS/$ID"; mkdir -p "$D"
  echo "task" > "$D/task.md"
  cat > "$CLAUDE_STUB" <<EOF
#!/bin/sh
printf '%s\n' "$OUT_LOG_BODY"
EOF
  chmod +x "$CLAUDE_STUB"
  # run-usage.sh не знайде реальну session-jsonl для фейкового claude —
  # підміняємо usage.json напряму ПІСЛЯ спавну через фейковий run-usage.sh,
  # щоб cc_out_tokens бачив контрольоване значення (--total_out).
  RUNUSAGE_STUB="$TMP/run-usage-$ID.sh"
  if [ "$USAGE_OUT" != "SKIP" ]; then
    cat > "$RUNUSAGE_STUB" <<EOF
#!/bin/sh
D=\$1
echo '{"total_out": $USAGE_OUT, "total_in": 1000}' > "\$D/usage.json"
echo "stub usage"
EOF
  else
    cat > "$RUNUSAGE_STUB" <<'EOF'
#!/bin/sh
echo "no usage available"
exit 2
EOF
  fi
  chmod +x "$RUNUSAGE_STUB"
  # Підміняємо run-usage.sh поряд з cc-run.sh: cc-run.sh шукає "$BIN/run-usage.sh"
  # відносно свого каталогу, тому копіюємо весь bin/ у ізольовану теку симлінками.
  FAKEBIN="$TMP/bin-$ID"
  mkdir -p "$FAKEBIN"
  for f in "$BIN"/*; do ln -sf "$f" "$FAKEBIN/$(basename "$f")"; done
  # cc-run.sh САМ copy, не symlink: readlink -f у скрипті резолвить symlink
  # до РЕАЛЬНОГО bin/, а не FAKEBIN — тоді $BIN/run-usage.sh знов вказав би
  # на справжній run-usage.sh, ігноруючи підміну нижче.
  rm -f "$FAKEBIN/cc-run.sh"
  cp "$BIN/cc-run.sh" "$FAKEBIN/cc-run.sh"
  chmod +x "$FAKEBIN/cc-run.sh"
  rm -f "$FAKEBIN/run-usage.sh"
  cp "$RUNUSAGE_STUB" "$FAKEBIN/run-usage.sh"
  chmod +x "$FAKEBIN/run-usage.sh"

  CC_RUNS="$CC_RUNS" CC_CLAUDE_BIN="$CLAUDE_STUB" CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
    sh "$FAKEBIN/cc-run.sh" "$D" none haiku >/dev/null 2>&1
  echo "$?"
}

# --- (a) реальний інцидент: 29 out-токенів, RESULT: ok -> гард ловить, exit 2 ---
RC=$(run_case "guard-a" "RESULT: ok" 29)
[ "$RC" = "2" ] || { echo "FAIL(a): очікував exit 2 (гард ловить <300 out), отримав $RC"; FAIL=1; }
D="$CC_RUNS/guard-a"
tail -1 "$D/out.log" | grep -q "^RESULT: fail" || { echo "FAIL(a): RESULT: fail не останній рядок out.log"; FAIL=1; }
grep -q "NOTES: no-work guard: out=29" "$D/out.log" || { echo "FAIL(a): нема NOTES no-work guard у out.log"; FAIL=1; }

# --- (b) нормальний ран: 5000 out-токенів + CHANGED -> RESULT: ok лишається, exit 0 ---
RC=$(run_case "guard-b" "CHANGED: bin/foo.sh
RESULT: ok" 5000)
[ "$RC" = "0" ] || { echo "FAIL(b): очікував exit 0 (нормальний ран), отримав $RC"; FAIL=1; }
tail -1 "$CC_RUNS/guard-b/out.log" | grep -q "^RESULT: ok" || { echo "FAIL(b): RESULT: ok мав лишитись останнім рядком"; FAIL=1; }

# --- (c) 5000 out-токенів, RESULT: ok, БЕЗ CHANGED -> гард все одно ловить ---
RC=$(run_case "guard-c" "RESULT: ok" 5000)
[ "$RC" = "2" ] || { echo "FAIL(c): очікував exit 2 (нема CHANGED), отримав $RC"; FAIL=1; }
grep -q "NOTES: no-work guard: out=5000" "$CC_RUNS/guard-c/out.log" || { echo "FAIL(c): нема NOTES no-work guard у out.log"; FAIL=1; }

# --- (d) usage.json недоступний (SKIP) — CHANGED є -> НЕ карати за невідомі токени ---
RC=$(run_case "guard-d" "CHANGED: bin/foo.sh
RESULT: ok" "SKIP")
[ "$RC" = "0" ] || { echo "FAIL(d): очікував exit 0 (out невідомий, CHANGED є — не карати), отримав $RC"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: гард нуль-роботи — <300 out ловить (a), нормальний ран проходить (b), нема CHANGED ловить (c), невідомий out не карає (d)"
