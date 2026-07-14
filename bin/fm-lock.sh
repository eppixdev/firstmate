#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry.
# Managed Codex sandboxes hide that process behind a PID namespace, so Codex
# falls back to a thread plus runtime-process identity resolved read-only by
# fm-codex-lock-identity.mjs.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it,
#                            exit 2 if identity or holder liveness is unavailable
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'
CODEX_LOCK_HELPER="${FM_CODEX_LOCK_HELPER:-$SCRIPT_DIR/fm-codex-lock-identity.mjs}"

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

session_identity() {
  local identity
  identity=$(harness_pid) && { printf '%s\n' "$identity"; return 0; }
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  [ -x "$CODEX_LOCK_HELPER" ] || return 1
  identity=$("$CODEX_LOCK_HELPER" current 2>/dev/null) || return 1
  case "$identity" in
    codex-thread:*) printf '%s\n' "$identity" ;;
    *) return 1 ;;
  esac
}

# Prints live, dead, or unknown for either the legacy harness PID or the
# managed-Codex token format.
holder_state() {
  local holder=$1 observer=${2:-} state
  case "$holder" in
    ''|*[!0-9]*)
      case "$holder" in
        codex-thread:*)
          [ -x "$CODEX_LOCK_HELPER" ] || { printf 'unknown\n'; return; }
          state=$("$CODEX_LOCK_HELPER" classify "$holder" 2>/dev/null) || state=unknown
          case "$state" in live|dead|unknown) printf '%s\n' "$state" ;; *) printf 'unknown\n' ;; esac
          ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    *)
      if holder_alive "$holder"; then
        printf 'live\n'
      elif [ "${observer#codex-thread:}" != "$observer" ]; then
        printf 'unknown\n'
      else
        printf 'dead\n'
      fi
      ;;
  esac
}

identity_label() {
  case "$1" in
    codex-thread:*) printf 'Codex thread %s\n' "$(printf '%s' "$1" | cut -d: -f2)" ;;
    *[!0-9]*) printf 'recorded session identity %s\n' "$1" ;;
    *) printf 'harness pid %s\n' "$1" ;;
  esac
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  observer=$(session_identity 2>/dev/null) || observer=
  state=$(holder_state "$old" "$observer")
  label=$(identity_label "$old")
  case "$state" in
    live) echo "lock: held by live $label" ;;
    dead) echo "lock: stale ($label is no longer live)" ;;
    *) echo "lock: indeterminate ($label liveness is unavailable)" ;;
  esac
  exit 0
fi

me=$(session_identity) || { echo "error: cannot establish a live session identity" >&2; exit 2; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ]; then
    state=$(holder_state "$old" "$me")
    if [ "$state" = live ]; then
      echo "error: another live firstmate session holds the lock ($(identity_label "$old")); operate read-only until resolved" >&2
      exit 1
    fi
    if [ "$state" = unknown ]; then
      echo "error: cannot determine whether the recorded firstmate session is still live ($(identity_label "$old"))" >&2
      exit 2
    fi
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: $(identity_label "$me")"
