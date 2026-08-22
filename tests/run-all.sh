#!/bin/sh
# Прогонити всі тести cc-swarm послідовно, звіт у кінці.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FAIL=0
for t in "$HERE"/test-*.sh; do
  echo "=== $(basename "$t") ==="
  if sh "$t"; then
    echo "--- $(basename "$t"): PASS ---"
  else
    echo "--- $(basename "$t"): FAIL ---"
    FAIL=1
  fi
  echo
done
if [ "$FAIL" = "1" ]; then
  echo "run-all: є провалені тести"
  exit 1
fi
echo "run-all: усі тести пройшли"
