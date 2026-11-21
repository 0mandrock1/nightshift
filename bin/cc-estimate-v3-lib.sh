#!/bin/sh
# Shared v3 adapter for the Nightshift shell drivers. The structured result is
# the only input to rendering and shadow admission.
cc_v3_enabled(){
  [ "${CC_ESTIMATE_V3:-1}" != 0 ] && [ -f "$BIN/cc-estimate-v3.py" ] && command -v python3 >/dev/null 2>&1 || return 1
  [ "$1" = codex ] && return 0
  [ "$1" = claude ] || return 1
  case "${CC_ESTIMATE_V3_CLAUDE:-auto}" in
    1) return 0 ;;
    auto) [ -f "${CC_ESTIMATE_STATE:-$CC_RUNS/.estimate-v3}/claude-enabled" ] ;;
    *) return 1 ;;
  esac
}

cc_resolve_model(){
  case "$1:$2" in
    codex:|codex:sonnet|codex:haiku) printf '%s\n' gpt-6-luna ;;
    codex:opus) printf '%s\n' gpt-6-sol ;;
    codex:gpt-*|claude:*) printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}

cc_v3_begin(){
  V3_PATH=""; V3_FACT=""; V3_START_NS=0; V3_START_EPOCH=0; V3_END_NS=0; V3_END_EPOCH=0
  cc_v3_enabled "$2" || return 1
  set -- "$1" "$2" "$3" "$4" "${CC_ESTIMATE_DEADLINE_EPOCH:-}"
  if [ -n "$5" ]; then
    set -- "$@" "--deadline=$5"
  fi
  v3_dir=$1; v3_backend=$2; v3_model=$3; v3_id=$4
  shift 5
  python3 "$BIN/cc-estimate-v3.py" predict --backend "$v3_backend" "--model=$v3_model" \
    "--effort=${CC_CODEX_EFFORT:-}" "--id=$v3_id" "--wrapper-pid=$$" --attempt --claude-quota \
    --output "$v3_dir/preflight-v3.json" "$@" >/dev/null 2>>"$v3_dir/preflight-error.log" || return 1
  V3_PATH="$v3_dir/preflight-v3.json"
}

cc_v3_clock(){
  [ -n "${V3_PATH:-}" ] || return 0
  v3_time=$(python3 "$BIN/cc-estimate-v3.py" clock) || return 0
  case "$1" in
    start) V3_START_NS=${v3_time% *}; V3_START_EPOCH=${v3_time#* } ;;
    end) V3_END_NS=${v3_time% *}; V3_END_EPOCH=${v3_time#* } ;;
  esac
}

cc_v3_finish(){
  [ -n "${V3_PATH:-}" ] || return 0
  if python3 "$BIN/cc-estimate-v3.py" finalize "$1" "$V3_PATH" "$2" "$3" \
    "$V3_START_NS" "$V3_START_EPOCH" "$V3_END_NS" "$V3_END_EPOCH" \
    2>>"$1/preflight-error.log"; then
    V3_FACT=$(python3 "$BIN/cc-estimate-v3.py" render-observation "$1/attempt-v3.json" \
      2>>"$1/preflight-error.log") || V3_FACT=""
  fi
}

cc_v3_render(){
  python3 "$BIN/cc-estimate-v3.py" render "$1"
}

cc_v3_stop_code(){
  [ "${CC_ESTIMATE_V3_ENFORCE:-1}" = 1 ] || return 1
  if [ -n "${CC_ESTIMATE_DEADLINE_EPOCH:-}" ]; then
    # Recheck after Telegram/telemetry I/O, including a legacy preflight fallback.
    if jq -en --arg epoch "$CC_ESTIMATE_DEADLINE_EPOCH" \
        '($epoch|tonumber) as $d | ($d|isfinite) and now >= $d' >/dev/null 2>&1; then
      printf '%s\n' 8
      return 0
    fi
  fi
  [ -n "${V3_PATH:-}" ] || return 1
  jq -er '.decision.reason | if .=="codex_provider_denied" then 3
    elif .=="deadline_elapsed" then 8 else empty end' "$V3_PATH" 2>/dev/null
}
