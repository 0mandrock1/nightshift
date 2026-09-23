#!/bin/sh
# Прогонити всі тести cc-swarm послідовно, звіт у кінці.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# CC_NOTIFY=/bin/true раніше валив `sh /bin/true` (ELF-бінарник як shell-скрипт,
# рятувало лише `|| true`); тестовий стаб — реальний sh-скрипт, exit 0.
export CC_NOTIFY=${CC_NOTIFY:-"$HERE/fixtures/notify-null.sh"}
# CC_USAGE_CLI: без цього кожен прогін cc-estimate.sh/cc-chain.sh бив по
# реальному usage-cli.js (~37 execve на прогін) — тестовий стаб віддає
# фіксовані "ліміти вільні", гейти тижня/ризику не спрацьовують.
export CC_USAGE_CLI=${CC_USAGE_CLI:-"$HERE/fixtures/usage-cli-stub.js"}
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
