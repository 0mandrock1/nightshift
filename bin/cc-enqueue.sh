#!/bin/sh
# Queue one existing Nightshift run directory behind a completed prerequisite.
# Usage: cc-enqueue.sh <run-dir> <prerequisite-run-dir> [timeout-s] [style] [model] [backend]
set -u

BIN=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE="$BIN/cc-queue-state.py"
RUN_DIR=${1:-}
PREREQ=${2:-}
TIMEOUT_S=${3:-3600}
STYLE=${4:-none}
MODEL=${5:-sonnet}
BACKEND=${6:-claude}
POLL_S=${CC_QUEUE_POLL_S:-5}
CC_RUN_SH=${CC_RUN_SH:-$BIN/cc-run.sh}
FINISHED=0

fail() { printf '%s\n' "queue error: $*" >&2; exit 2; }
[ -n "$RUN_DIR" ] && [ -n "$PREREQ" ] || fail "run-dir and prerequisite-run-dir are required"
[ -d "$RUN_DIR" ] || fail "run directory must already exist; queue admission does not create phantom runs"
[ -f "$RUN_DIR/task.md" ] || fail "task.md is required before queue admission"
[ -d "$PREREQ" ] || fail "prerequisite run directory does not exist"
case "$TIMEOUT_S:$POLL_S" in *[!0-9:]*|:*) fail "timeout and poll interval must be positive integers" ;; esac
[ "$TIMEOUT_S" -gt 0 ] && [ "$POLL_S" -gt 0 ] || fail "timeout and poll interval must be positive integers"
[ ! -e "$RUN_DIR/exit_code" ] || fail "run already has exit_code"
[ ! -e "$RUN_DIR/queue.meta" ] || fail "run already has queue metadata"
[ -x "$CC_RUN_SH" ] || fail "cc-run.sh is missing or not executable: $CC_RUN_SH"
[ -x "$STATE" ] || fail "queue state helper is missing or not executable: $STATE"

exec 9>"$RUN_DIR/queue.lock"
flock -n 9 || fail "queue lock is already held"
LOG="$RUN_DIR/queue.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
publish() { python3 "$STATE" "$RUN_DIR" "$1" "${2:-}" "${3:-}"; }
on_exit() {
  rc=$?
  if [ "$FINISHED" -eq 0 ]; then
    publish FAILED || true
    log "worker exited unexpectedly rc=$rc"
  fi
  exit "$rc"
}
trap on_exit 0
trap 'exit 143' HUP INT TERM

publish QUEUED || exit 1
log "queued behind $PREREQ; timeout=${TIMEOUT_S}s"
queued_epoch=$(date -u +%s)
while [ ! -s "$PREREQ/exit_code" ]; do
  now=$(date -u +%s)
  if [ $((now - queued_epoch)) -ge "$TIMEOUT_S" ]; then
    log "queue timeout waiting for prerequisite exit_code"
    publish TIMEOUT || exit 1
    FINISHED=1
    exit 124
  fi
  sleep "$POLL_S"
done

prereq_exit=$(tr -d '[:space:]' < "$PREREQ/exit_code")
prereq_result=$(grep -E 'RESULT:[[:space:]]*\**[[:space:]]*(ok|fail)' "$PREREQ/out.log" 2>/dev/null | tail -n 1 | sed -E 's/.*RESULT:[[:space:]]*\**[[:space:]]*(ok|fail).*/\1/')
if [ "$prereq_exit" != 0 ] || [ "$prereq_result" != ok ]; then
  log "blocked: prerequisite exit=$prereq_exit result=${prereq_result:-missing}"
  publish BLOCKED || exit 1
  FINISHED=1
  exit 10
fi

publish STARTING || exit 1
started_at=$(date -u +%FT%TZ)
publish RUNNING "$started_at" || exit 1
log "starting runner"
set +e
sh "$CC_RUN_SH" "$RUN_DIR" "$STYLE" "$MODEL" "$BACKEND" >>"$LOG" 2>&1
rc=$?
set -e
ended_at=$(date -u +%FT%TZ)
if [ "$rc" -eq 0 ]; then
  publish COMPLETE "$started_at" "$ended_at" || exit 1
else
  publish FAILED "$started_at" "$ended_at" || exit 1
fi
log "runner returned rc=$rc"
FINISHED=1
exit "$rc"
