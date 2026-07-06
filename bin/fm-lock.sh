#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

harness_component_name() {
  local name=$1
  local bare=${name#.}
  case "$name" in
    claude|codex|opencode|grok|pi)
      printf '%s\n' "$name"
      return 0
      ;;
  esac
  case "$bare" in
    claude|codex|opencode|grok|pi)
      printf '%s\n' "$bare"
      return 0
      ;;
  esac
  case "${name%.*}" in
    claude|codex|opencode|grok|pi)
      printf '%s\n' "${name%.*}"
      return 0
      ;;
  esac
  case "${bare%.*}" in
    claude|codex|opencode|grok|pi)
      printf '%s\n' "${bare%.*}"
      return 0
      ;;
  esac
  case "$name" in
    claude[-_.]*)
      printf '%s\n' claude
      return 0
      ;;
    codex[-_.]*)
      printf '%s\n' codex
      return 0
      ;;
    opencode[-_.]*)
      printf '%s\n' opencode
      return 0
      ;;
    grok[-_.]*)
      printf '%s\n' grok
      return 0
      ;;
  esac
  return 1
}

# Known harness command names; extend when a new adapter is verified.

harness_token_name() {
  local token=$1 name
  name=$(basename -- "$token")
  harness_component_name "$name" && return 0
  while [ "$token" != "${token%/*}" ]; do
    token=${token%/*}
    name=$(basename -- "$token")
    harness_component_name "$name" && return 0
  done
  harness_component_name "$token" && return 0
  return 1
}

harness_token_is_verified() {
  harness_token_name "$1" >/dev/null
}

args_command_base() {
  local args=$1
  local -a argv=()
  read -r -a argv <<< "$args"
  [ "${#argv[@]}" -gt 0 ] || return 1
  basename -- "${argv[0]}"
}

wrapped_harness_token() {
  local base=$1 args=$2
  local -a argv=()
  local i token
  read -r -a argv <<< "$args"
  [ "${#argv[@]}" -gt 0 ] || return 1
  case "$base" in
    bwrap)
      for ((i=1; i<${#argv[@]}; i++)); do
        [ "${argv[$i]}" = "--" ] || continue
        i=$((i + 1))
        [ "$i" -lt "${#argv[@]}" ] || return 1
        printf '%s\n' "${argv[$i]}"
        return 0
      done
      ;;
    node|nodejs)
      i=1
      while [ "$i" -lt "${#argv[@]}" ]; do
        token=${argv[$i]}
        case "$token" in
          -e|-p|--eval|--print) return 1 ;;
          -r|--require|--loader|--import) i=$((i + 2)); continue ;;
          --)
            i=$((i + 1))
            [ "$i" -lt "${#argv[@]}" ] || return 1
            printf '%s\n' "${argv[$i]}"
            return 0
            ;;
          -*)
            i=$((i + 1))
            continue
            ;;
          *)
            printf '%s\n' "$token"
            return 0
            ;;
        esac
      done
      ;;
    python|python[0-9]*)
      i=1
      while [ "$i" -lt "${#argv[@]}" ]; do
        token=${argv[$i]}
        case "$token" in
          -c|-m) return 1 ;;
          -W|-X) i=$((i + 2)); continue ;;
          --)
            i=$((i + 1))
            [ "$i" -lt "${#argv[@]}" ] || return 1
            printf '%s\n' "${argv[$i]}"
            return 0
            ;;
          -*)
            i=$((i + 1))
            continue
            ;;
          *)
            printf '%s\n' "$token"
            return 0
            ;;
        esac
      done
      ;;
  esac
  return 1
}

process_is_harness() {
  local comm=$1 args=$2 base token
  base=$(basename -- "$comm")
  harness_token_is_verified "$base" && return 0
  if token=$(wrapped_harness_token "$base" "$args"); then
    harness_token_is_verified "$token" && return 0
  fi

  base=$(args_command_base "$args") || return 1
  harness_token_is_verified "$base" && return 0
  if token=$(wrapped_harness_token "$base" "$args"); then
    harness_token_is_verified "$token" && return 0
  fi
  return 1
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    process_is_harness "$comm" "$args" && { echo "$pid"; return 0; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 0 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  process_is_harness "$comm" "$args"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
