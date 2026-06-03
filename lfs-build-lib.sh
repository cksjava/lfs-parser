#!/usr/bin/env bash
# Shared LFS build logging and resume helpers (sourced by package scripts).
# Do not execute directly.

[[ -n "${LFS_BUILD_LIB_LOADED:-}" ]] && return 0
LFS_BUILD_LIB_LOADED=1

LFS_BUILD_LIB_VERSION=1

# --- paths (override with env) ---
lfs_build_lib_init() {
  if [[ -n "${LFS_BUILD_LIB_READY:-}" ]]; then
    return 0
  fi

  if [[ -z "${LFS_SCRIPTS_DIR:-}" ]]; then
    if [[ -n "${_LFS_SCRIPTS_ROOT:-}" ]]; then
      LFS_SCRIPTS_DIR="$_LFS_SCRIPTS_ROOT"
    else
      echo "lfs-build-lib: LFS_SCRIPTS_DIR or _LFS_SCRIPTS_ROOT required" >&2
      return 1
    fi
  fi

  LFS_BUILD_LOG_DIR="${LFS_BUILD_LOG_DIR:-$LFS_SCRIPTS_DIR/logs}"
  LFS_EVENTS_LOG="${LFS_EVENTS_LOG:-$LFS_BUILD_LOG_DIR/build-events.jsonl}"
  LFS_COMPLETED_FILE="${LFS_COMPLETED_FILE:-$LFS_BUILD_LOG_DIR/completed-scripts}"
  mkdir -p "$LFS_BUILD_LOG_DIR"
  LFS_BUILD_LIB_READY=1
  return 0
}

# Escape a string for JSON (no newlines).
lfs_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Append one JSON object line to the event log.
# Usage: lfs_log event [key=value ...]
#   lfs_log message "text=hello"
#   lfs_log start  (uses LFS_SCRIPT_* context)
lfs_log() {
  local event="$1"
  shift
  lfs_build_lib_init || return 1

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)

  local json
  json=$(printf '{"event":"%s","ts":"%s"' "$(lfs_json_escape "$event")" "$ts")

  if [[ -n "${LFS_SCRIPT_ID:-}" ]]; then
    json+=$(printf ',"script":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_ID")")
  fi
  if [[ -n "${LFS_SCRIPT_TITLE:-}" ]]; then
    json+=$(printf ',"title":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_TITLE")")
  fi
  if [[ -n "${LFS_SCRIPT_SOURCE:-}" ]]; then
    json+=$(printf ',"source":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_SOURCE")")
  fi
  if [[ -n "${LFS_SCRIPT_CHAPTER:-}" ]]; then
    json+=$(printf ',"chapter":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_CHAPTER")")
  fi
  if [[ -n "${LFS_SCRIPT_STAGE:-}" ]]; then
    json+=$(printf ',"stage":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_STAGE")")
  fi
  if [[ -n "${LFS_SCRIPT_SESSION:-}" ]]; then
    json+=$(printf ',"session":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_SESSION")")
  fi
  if [[ -n "${LFS_SCRIPT_PACKAGE:-}" ]]; then
    json+=$(printf ',"package":"%s"' "$(lfs_json_escape "$LFS_SCRIPT_PACKAGE")")
  fi

  while [[ $# -gt 0 ]]; do
    local kv=$1
    shift
    local key=${kv%%=*}
    local val=${kv#*=}
    json+=$(printf ',"%s":"%s"' "$(lfs_json_escape "$key")" "$(lfs_json_escape "$val")")
  done

  json+='}'
  echo "$json" >>"$LFS_EVENTS_LOG"
}

# True if this script already completed successfully.
lfs_script_is_done() {
  lfs_build_lib_init || return 1
  [[ "${LFS_FORCE_RERUN:-0}" == "1" ]] && return 1
  [[ -n "${LFS_SCRIPT_ID:-}" && -f "$LFS_COMPLETED_FILE" ]] || return 1
  grep -qxF "$LFS_SCRIPT_ID" "$LFS_COMPLETED_FILE" 2>/dev/null
}

# Exit 0 if already built; otherwise log start and install ERR trap.
# Usage: lfs_script_begin <script_id> <title> <source> <chapter> <stage> <session> [package]
lfs_script_begin() {
  LFS_SCRIPT_ID=$1
  LFS_SCRIPT_TITLE=$2
  LFS_SCRIPT_SOURCE=$3
  LFS_SCRIPT_CHAPTER=$4
  LFS_SCRIPT_STAGE=$5
  LFS_SCRIPT_SESSION=$6
  LFS_SCRIPT_PACKAGE=${7:-}
  LFS_SCRIPT_FINISHED=0
  LFS_SCRIPT_START_EPOCH=$(date +%s 2>/dev/null || echo 0)

  lfs_build_lib_init || return 1

  if lfs_script_is_done; then
    lfs_log skip status=skipped reason=already_completed
    echo "lfs-build-lib: skip (already completed): $LFS_SCRIPT_ID"
    return 0
  fi

  lfs_log start status=running
  trap 'lfs_script_finish failure' ERR
}

# Record end time, duration, result; mark completed on success.
# Usage: lfs_script_finish success|failure|skipped
lfs_script_finish() {
  local status=${1:-success}
  [[ "${LFS_SCRIPT_FINISHED:-0}" == "1" ]] && return 0
  LFS_SCRIPT_FINISHED=1

  lfs_build_lib_init || return 0

  local end_epoch duration
  end_epoch=$(date +%s 2>/dev/null || echo 0)
  duration=$((end_epoch - LFS_SCRIPT_START_EPOCH))
  [[ "$duration" -lt 0 ]] && duration=0

  lfs_log end status="$status" duration_sec="$duration"

  if [[ "$status" == "success" && -n "${LFS_SCRIPT_ID:-}" ]]; then
    if ! grep -qxF "$LFS_SCRIPT_ID" "$LFS_COMPLETED_FILE" 2>/dev/null; then
      echo "$LFS_SCRIPT_ID" >>"$LFS_COMPLETED_FILE"
    fi
  fi

  [[ "$status" == "failure" ]] && return 1
  return 0
}
