#!/bin/sh
# Пост-фліт вартість рану з usage.json + скільки той самий ран коштував би
# на sonnet. Best-effort: нема usage.json/jq — тихо виходить 0.
#
#   sh cc-cost.sh <run-dir>   -> рядок у stdout, дублюється в telemetry.log
#
# Прайс $/M токенів. Sonnet рівно в 5 разів дешевший за opus на КОЖНІЙ статті,
# тому «sonnet-еквівалент» для opus-рану — це просто /5.
set -u
D=${1:?run-dir}; D=${D%/}
CC_RUNS=${CC_RUNS:-$(getent passwd "$(id -un)" | cut -d: -f6)/ops/cc-runs}
LOG=${CC_TELEMETRY_LOG:-$CC_RUNS/telemetry.log}
[ -f "$D/usage.json" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

LINE=$(jq -r '
  def price(m):
    if   (m|test("opus"))   then {i:15,   o:75, cw:18.75, cr:1.50}
    elif (m|test("sonnet")) then {i:3,    o:15, cw:3.75,  cr:0.30}
    elif (m|test("haiku"))  then {i:1,    o:5,  cw:1.25,  cr:0.10}
    else {i:3, o:15, cw:3.75, cr:0.30} end;
  def tier(m):
    if (m|test("opus")) then "opus" elif (m|test("sonnet")) then "sonnet"
    elif (m|test("haiku")) then "haiku" else "?" end;
  [ .models[] | price(.model) as $p
    | { t: tier(.model),
        usd: ((.input*$p.i + .output*$p.o + .cache_w*$p.cw + .cache_r*$p.cr) / 1000000),
        cr: .cache_r, tot: (.input + .cache_w + .cache_r + .output) } ] as $m
  | ($m | map(.usd) | add) as $usd
  | ($m | map(.tot) | add) as $tot
  | ($m | map(.cr)  | add) as $cr
  | ($m | map(select(.t=="opus") | .usd) | add // 0) as $ousd
  | "\(.run): \($tot) токенів (cache_read \(($cr*100/$tot)|floor)%), $\($usd*100|round/100)"
    + (if $ousd > 0 then " | sonnet-еквівалент $\(($usd - $ousd*0.8)*100|round/100) — переплата $\($ousd*0.8*100|round/100)" else "" end)
' "$D/usage.json" 2>/dev/null)

[ -n "$LINE" ] || exit 0
echo "$LINE" | tee -a "$D/cost.log"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cost: $LINE" >> "$LOG"
exit 0
