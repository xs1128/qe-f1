# Logging, error handling and small helpers.
# shellcheck shell=bash

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'
  _c_bold=$'\033[1m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=''; _c_green=''; _c_yellow=''; _c_bold=''; _c_dim=''; _c_off=''
fi

log_init() {
  LOG_FILE=$1
  mkdir -p -- "$(dirname -- "$LOG_FILE")"
  : >"$LOG_FILE"
}

_log() {
  [[ -n ${LOG_FILE:-} ]] || return 0
  printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG_FILE"
}

step() { printf '%s==>%s %s\n' "$_c_bold" "$_c_off" "$*"; _log "STEP $*"; }
info() { printf '    %s\n' "$*"; _log "INFO $*"; }
ok()   { printf '    %s%s%s\n' "$_c_green" "$*" "$_c_off"; _log "OK $*"; }
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; _log "WARN $*"; }

die() {
  printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2
  _log "ERROR $*"
  [[ -n ${LOG_FILE:-} ]] && printf '       full log: %s\n' "$LOG_FILE" >&2
  exit 1
}

# Run a command with its output captured to the log, showing only progress.
# Use `run "description" cmd args...` and check the return value.
#
# Set RUN_OUTPUT=path for the call to send the command's output to that file as
# well as the log, for when the output is itself an artefact worth keeping.
run() {
  local desc=$1; shift
  local sink=${RUN_OUTPUT:-}
  local rc=0
  _log "RUN $*"

  if [[ ${VERBOSE:-0} == 1 ]]; then
    printf '    %s%s%s\n' "$_c_dim" "$desc" "$_c_off"
    if [[ -n $sink ]]; then
      "$@" >"$sink" 2>&1; rc=$?
      cat -- "$sink" | tee -a "$LOG_FILE"
    else
      "$@" 2>&1 | tee -a "$LOG_FILE"
      rc=${PIPESTATUS[0]}
    fi
    return "$rc"
  fi

  printf '    %s ... ' "$desc"
  if [[ -n $sink ]]; then
    "$@" >"$sink" 2>&1 || rc=$?
    cat -- "$sink" >>"$LOG_FILE" 2>/dev/null || true
  else
    "$@" >>"$LOG_FILE" 2>&1 || rc=$?
  fi
  if ((rc == 0)); then
    printf '%sdone%s\n' "$_c_green" "$_c_off"
  else
    printf '%sfailed%s\n' "$_c_red" "$_c_off"
  fi
  return "$rc"
}

require_cmd() {
  local c missing=()
  for c in "$@"; do
    command -v -- "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool found (need sha256sum or shasum)"
  fi
}

verify_sha256() {
  local path=$1 expected=$2 actual
  actual=$(sha256_of "$path")
  [[ $actual == "$expected" ]]
}

# Free space in MiB on the filesystem holding $1 (walks up to an existing dir).
free_mib() {
  local d=$1
  while [[ ! -d $d && $d != / ]]; do d=$(dirname -- "$d"); done
  df -Pm -- "$d" | awk 'NR==2 {print $4}'
}
