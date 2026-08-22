#!/bin/sh
# Стаб бекенду Tier 0 (локальна квантована модель, RTX 3060). Фаза 2 — тут лише
# точка розширення, щоб cc-swarm.sh мав кого викликати за префіксом `local:` і не
# дописувати цю гілку рефактором пізніше.
#
#   sh cc-lane-local.sh <run-dir> [style] [model]
#     model прийде як "local:<tag>" (той самий аргумент, що й у cc-run.sh)
#
# Коди виходу: завжди 2 (fail), доки не реалізовано
set -u

D=${1:?run-dir}; D=${D%/}
STYLE=${2:-none}
MODEL=${3:-}

echo "RESULT: fail" > "$D/out.log"
echo "NOTES: локальний бекенд ще не реалізований, фаза 2 (model=$MODEL, style=$STYLE)" >> "$D/out.log"
echo 2 > "$D/exit_code"
exit 2
