#!/bin/sh
# Гард дорогої моделі. Викликається ПЕРЕД спавном claude -p.
#
#   sh cc-opus-gate.sh <model> <run-id>
#
# Пропускає все, крім opus. Opus вимагає явного CC_OPUS_REASON — одного рядка
# про те, яке саме АРХІТЕКТУРНЕ рішення робить ран. Причина в тому, що opus
# коштує рівно 5x за токен на всіх статтях (in/out/cache), а 95%+ обсягу
# будь-якого рану — це cache_read зростаючого транскрипту. Тобто ціна рану
# майже цілком визначається множником моделі, а не тим, як щільно написано
# task.md. Виконавча робота на opus — це та сама робота за 5x.
#
# Коди виходу: 0 пропустити | 6 відмова (opus без причини)
set -u
MODEL=${1:-}
RUN_ID=${2:-?}
CC_RUNS=${CC_RUNS:-$HOME/ops/cc-runs}
LOG=${CC_TELEMETRY_LOG:-$CC_RUNS/telemetry.log}

case "$MODEL" in
  *opus*) ;;
  *) exit 0 ;;
esac

if [ -n "${CC_OPUS_REASON:-}" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] opus-gate: ПРОПУЩЕНО $RUN_ID — $CC_OPUS_REASON" >> "$LOG"
  exit 0
fi

cat >&2 <<MSG
ВІДМОВА opus-gate: ран '$RUN_ID' просить opus без CC_OPUS_REASON.

Opus коштує 5x за токен на всіх статтях. Оскільки 95%+ обсягу рану — це
cache_read транскрипту, вибір моделі і Є основним важелем ціни рану.

Якщо ран РОБИТЬ АРХІТЕКТУРНЕ РІШЕННЯ (обирає підхід, розводить абстракції,
знаходить причину неочевидного бага) — назви його явно:

  CC_OPUS_REASON="чому саме opus" sh cc-run.sh $RUN_ID <style> opus

Якщо ран ВИКОНУЄ вже прийняте рішення (правка за специфікацією, конвертація,
верстка, прогін тестів, рефактор за зразком) — це sonnet:

  sh cc-run.sh $RUN_ID <style> sonnet
MSG
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] opus-gate: ВІДМОВА $RUN_ID — opus без CC_OPUS_REASON" >> "$LOG"
exit 6
