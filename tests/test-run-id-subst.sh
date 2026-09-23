#!/bin/sh
# cc-run.sh підставляє {RUN_ID} у task.md реальним id рану (basename run-dir),
# так само як cc-chain.sh; claude отримує вже підставлений текст.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0
D="$TMP/runs/rid-test-20260923-0000"
mkdir -p "$D"
printf 'Гілка cc/{RUN_ID}, файл NOTES-{RUN_ID}.md\n' > "$D/task.md"
STUB="$TMP/stub.sh"
cat > "$STUB" <<'S'
#!/bin/sh
for a in "$@"; do case "$a" in *"{RUN_ID}"*) echo "SAW_PLACEHOLDER";; esac; done
echo "RESULT: ok"
S
chmod +x "$STUB"
CC_RUNS="$TMP/runs" CC_CLAUDE_BIN="$STUB" CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
  sh "$BIN/cc-run.sh" "$D" none haiku >/dev/null 2>&1
grep -q '{RUN_ID}' "$D/task.md" && { echo "FAIL: плейсхолдер лишився в task.md"; FAIL=1; }
[ "$(grep -c 'rid-test-20260923-0000' "$D/task.md")" -ge 1 ] || { echo "FAIL: id не підставлено"; FAIL=1; }
grep -q SAW_PLACEHOLDER "$D/out.log" 2>/dev/null && { echo "FAIL: claude отримав непідставлений текст"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "PASS test-run-id-subst"
exit $FAIL
