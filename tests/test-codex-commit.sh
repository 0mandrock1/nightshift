#!/bin/sh
# Автокоміт wrapper'а для BACKEND=codex (варіант (a), рішення Марка): codex
# під sandbox workspace-write не пише в .git, тож коміт незакомічених змін
# після RESULT: ok робить cc-run.sh сам, у батьківському процесі, поза
# sandbox codex. Той самий фейковий CC_CODEX_BIN, що й у
# tests/test-codex-backend.sh / tests/test-chain-codex.sh.
#   (i)   codex змінює файл + RESULT: ok -> коміт є, "codex(...)" у msg,
#         COMMIT: <sha> в out.log == HEAD
#   (ii)  codex нічого не міняє          -> COMMIT: none, HEAD не зрушив
#   (iii) коміт неможливий (нема ідентичності автора) -> exit 2
#   (iv)  pre-commit hook з файлом-маркером -> після коміту маркера немає
#         (доказ core.hooksPath=/dev/null, а не --no-verify)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

# --- фейковий codex CLI: -c CHANGE=1 (через env) міняє файл f у CWD,
# інакше лишає дерево чистим. Завжди друкує RESULT: ok. ---
STUB="$TMP/fake-codex"
cat > "$STUB" <<'EOF'
#!/bin/sh
set -u
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    exec) shift ;;
    -o) OUT=$2; shift 2 ;;
    -m|-s|-C|--add-dir|-c) shift 2 ;;
    --skip-git-repo-check|--json) shift ;;
    *) shift ;;
  esac
done
echo '{"type":"thread.started"}' >&2
CHVAL="none"
if [ "${CC_STUB_CHANGE:-0}" = "1" ]; then
  echo "змінено codex-stub'ом" >> f
  CHVAL="f"
fi
# turn.completed на stdout -> events.jsonl, output_tokens>=300 щоб не
# зачепити cc_no_work_guard (estimator v2, 30.09) — фейковий codex інакше
# завжди мав out=0, guard переписував би RESULT на fail до перевірок нижче.
echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":400}}'
# NOTES/CHANGED перед RESULT — той самий порядок, що вимагає реальний контракт
# task.md (CHANGED передостаннім, RESULT завжди строго останній рядок відповіді).
printf 'NOTES: stub codex-commit test\nCHANGED: %s\nRESULT: ok\n' "$CHVAL" > "$OUT"
exit 0
EOF
chmod +x "$STUB"

mk_repo(){
  R=$1
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  echo x > "$R/f"
  git -C "$R" add f
  git -C "$R" commit -qm init
}

run_case(){
  # RUNS DIR REPO CHANGE
  D=$1; REPO=$2; CHANGE=$3
  mkdir -p "$D"
  echo "task $(basename "$D")" > "$D/task.md"
  ( cd "$REPO" && \
    CC_RUNS="$RUNS" CC_CODEX_BIN="$STUB" CC_STUB_CHANGE="$CHANGE" \
    CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
    sh "$BIN/cc-run.sh" "$D" none sonnet codex ) >"$D/wrapper.out" 2>&1
  return $?
}

# Той самий кейс, але без git-ідентичності автора (порожні GIT_AUTHOR_*/
# GIT_COMMITTER_*, щоб не підхопити глобальний ~/.gitconfig root'а) -
# git commit гарантовано впаде "empty ident name".
run_case_noident(){
  D=$1; REPO=$2; CHANGE=$3
  mkdir -p "$D"
  echo "task $(basename "$D")" > "$D/task.md"
  ( cd "$REPO" && \
    CC_RUNS="$RUNS" CC_CODEX_BIN="$STUB" CC_STUB_CHANGE="$CHANGE" \
    CC_NOTIFY="$HERE/fixtures/notify-null.sh" \
    GIT_AUTHOR_NAME='' GIT_AUTHOR_EMAIL='' GIT_COMMITTER_NAME='' GIT_COMMITTER_EMAIL='' \
    sh "$BIN/cc-run.sh" "$D" none sonnet codex ) >"$D/wrapper.out" 2>&1
  return $?
}

RUNS="$TMP/runs"

# --- (i) зміна + RESULT ok -> коміт є ---
REPO1="$TMP/repo1"; mk_repo "$REPO1"
BASE1=$(git -C "$REPO1" rev-parse HEAD)
run_case "$RUNS/case-i" "$REPO1" 1; RC=$?
[ "$RC" = "0" ] || { echo "FAIL(i): очікував exit 0, отримав $RC ($(cat "$RUNS/case-i/wrapper.out" 2>/dev/null))"; FAIL=1; }
HEAD1=$(git -C "$REPO1" rev-parse HEAD)
[ "$HEAD1" != "$BASE1" ] || { echo "FAIL(i): HEAD не зрушив попри зміну"; FAIL=1; }
git -C "$REPO1" log -1 --pretty=%B | grep -q "^codex(case-i):" || { echo "FAIL(i): повідомлення коміту не codex(...)"; FAIL=1; }
COMMITLINE1=$(grep -aE '^COMMIT: ' "$RUNS/case-i/out.log" | tail -1 | sed 's/^COMMIT: //')
[ "$COMMITLINE1" = "$(git -C "$REPO1" rev-parse --short HEAD)" ] || { echo "FAIL(i): COMMIT: у out.log ('$COMMITLINE1') != HEAD ('$(git -C "$REPO1" rev-parse --short HEAD)')"; FAIL=1; }
tail -1 "$RUNS/case-i/out.log" | grep -q "^RESULT: ok" || { echo "FAIL(i): RESULT: ok не лишився останнім рядком out.log"; FAIL=1; }

# --- (ii) без змін -> COMMIT: none, HEAD не зрушив ---
REPO2="$TMP/repo2"; mk_repo "$REPO2"
BASE2=$(git -C "$REPO2" rev-parse HEAD)
run_case "$RUNS/case-ii" "$REPO2" 0; RC=$?
[ "$RC" = "0" ] || { echo "FAIL(ii): очікував exit 0, отримав $RC"; FAIL=1; }
HEAD2=$(git -C "$REPO2" rev-parse HEAD)
[ "$HEAD2" = "$BASE2" ] || { echo "FAIL(ii): HEAD зрушив попри чисте дерево"; FAIL=1; }
grep -aq "^COMMIT: none" "$RUNS/case-ii/out.log" || { echo "FAIL(ii): нема 'COMMIT: none' в out.log"; FAIL=1; }

# --- (iii) коміт неможливий (нема ідентичності автора) -> exit 2 ---
REPO3="$TMP/repo3"; mk_repo "$REPO3"
git -C "$REPO3" config --unset user.email
git -C "$REPO3" config --unset user.name
git -C "$REPO3" config user.useConfigOnly true
BASE3=$(git -C "$REPO3" rev-parse HEAD)
run_case_noident "$RUNS/case-iii" "$REPO3" 1; RC=$?
[ "$RC" = "2" ] || { echo "FAIL(iii): очікував exit 2, отримав $RC ($(cat "$RUNS/case-iii/wrapper.out" 2>/dev/null))"; FAIL=1; }
HEAD3=$(git -C "$REPO3" rev-parse HEAD)
[ "$HEAD3" = "$BASE3" ] || { echo "FAIL(iii): HEAD зрушив попри провал коміту"; FAIL=1; }
tail -1 "$RUNS/case-iii/out.log" | grep -q "^RESULT: fail" || { echo "FAIL(iii): RESULT: fail не лишився останнім рядком out.log"; FAIL=1; }
grep -aq "^COMMIT: FAILED" "$RUNS/case-iii/out.log" || { echo "FAIL(iii): нема 'COMMIT: FAILED' в out.log"; FAIL=1; }

# --- (iv) pre-commit hook з маркером -> маркера після коміту немає ---
REPO4="$TMP/repo4"; mk_repo "$REPO4"
mkdir -p "$REPO4/.git/hooks"
MARKER="$TMP/hook-fired-marker"
rm -f "$MARKER"
cat > "$REPO4/.git/hooks/pre-commit" <<EOF
#!/bin/sh
touch "$MARKER"
exit 0
EOF
chmod +x "$REPO4/.git/hooks/pre-commit"
run_case "$RUNS/case-iv" "$REPO4" 1; RC=$?
[ "$RC" = "0" ] || { echo "FAIL(iv): очікував exit 0, отримав $RC"; FAIL=1; }
[ -f "$MARKER" ] && { echo "FAIL(iv): pre-commit hook спрацював попри core.hooksPath=/dev/null"; FAIL=1; }

if [ "$FAIL" = "1" ]; then exit 1; fi
echo "OK: codex-автокоміт — зміна->коміт, чисто->none, провал коміту->exit 2, hooks заблоковані"
