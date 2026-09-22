#!/bin/sh
# Чекає тиші, робить cutover, E2E-перевірка, при провалі — rollback. Максимум 12 год.
set -u
OPS=/root/ops/cc-runs
cp /root/projects/cc-swarm/ops/cutover-e1b.sh /root/projects/cc-swarm/ops/rollback-e1b.sh /tmp/
P='claude'' -p'
# rc і stderr нотифікації — у notify-debug.log бекап-теки (як у cc-run.sh),
# не в /dev/null; best-effort — ніколи не валить waiter.
note(){ { echo "--- note $(date -u +%FT%TZ) ---"; sh "$OPS/cc-notify.sh" "🔀 e1b-cutover · $1"; echo "note rc=$?"; } >>"${BK:-/tmp}/notify-debug.log" 2>&1 || true; }

defer_soon(){
  now=$(date +%s)
  for t in $(systemctl list-timers --all --no-legend 'cc-defer-*' | grep -o 'cc-defer-[^ ]*\.timer'); do
    n=$(systemctl show "$t" -p NextElapseUSecRealtime --value)
    [ -n "$n" ] || continue
    e=$(date -d "$n" +%s 2>/dev/null) || continue
    [ $((e - now)) -lt 3600 ] && [ "$e" -gt "$now" ] && return 0
  done
  return 1
}

i=0
while :; do
  if ! pgrep -f "$P" >/dev/null && ! pgrep -f 'cc-(run|chain|seq|swarm)\.sh' >/dev/null && ! defer_soon; then break; fi
  i=$((i + 1)); [ $i -ge 720 ] && { note "12 год не було тиші — здаюсь, нічого не змінено"; exit 1; }
  sleep 60
done

rm -f /tmp/e1b-bk
OUT=$(sh /tmp/cutover-e1b.sh 2>&1) || {
  if [ -f /tmp/e1b-bk ]; then
    sh /tmp/rollback-e1b.sh "$(cat /tmp/e1b-bk)" >/dev/null 2>&1
    note "ABORT після мутації: $(echo "$OUT" | tail -1) — відкочено"
  else
    note "ABORT до мутації: $(echo "$OUT" | tail -1)"
  fi
  exit 1
}
BK=$(echo "$OUT" | tail -1)

fail(){ sh /tmp/rollback-e1b.sh "$BK" >/dev/null 2>&1; note "VERIFY FAIL ($1) — відкочено, бекап $BK"; exit 1; }
TL0=$(wc -l < "$OPS/telemetry.log" 2>/dev/null || echo 0)
sh "$OPS/cc-week-guard.sh" >/dev/null 2>&1 || fail week-guard
cc-runs >/dev/null 2>&1 || fail cc-runs-cli
D=$OPS/e1b-cutover-verify-$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$D"
echo 'Нічого не роби. Виведи рівно один рядок: RESULT: ok' > "$D/task.md"
CC_TAG=e1b-cutover sh "$OPS/cc-run.sh" "$D" none haiku >"$D/wrap.log" 2>&1 || fail "cc-run exit $?"
grep -q 'RESULT:[[:space:]]*ok' "$D/out.log" || fail "нема RESULT ok"
TL1=$(wc -l < "$OPS/telemetry.log" 2>/dev/null || echo 0)
[ "$TL1" -gt "$TL0" ] || fail "telemetry.log не виріс"
note "OK · CORE → nightshift/bin · бекап $BK · перевір, що ця нотифікація і нотифікація noop-рану прийшли"
