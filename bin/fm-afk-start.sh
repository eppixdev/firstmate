#!/usr/bin/env bash
# Start away-mode supervision from the tmux server, not from the current tool
# command's process tree.
#
# Some agent harnesses clean up all descendants of a completed tool command.
# A plain `nohup bin/fm-supervise-daemon.sh &` can therefore die with its
# launcher, leaving state/.afk present but no long-lived daemon owner. Starting
# through `tmux run-shell -b` makes the tmux server own the daemon process, which
# matches the daemon's tmux-only injection model and survives tool teardown.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"
PIDFILE="$STATE/.supervise-daemon.pid"
LOCK="$STATE/.supervise-daemon.lock"
LAUNCH_LOG="$STATE/.supervise-daemon.launch.log"
CONFIRM_TIMEOUT=${FM_AFK_START_CONFIRM_TIMEOUT:-10}

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tmux-lib.sh"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

pidfile_alive() {
  local pid lock_pid identity
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  [ -n "$pid" ] \
    && fm_pid_alive "$pid" \
    || return 1
  if fm_watcher_lock_matches_pid "$LOCK" "$pid" "$DAEMON" "$FM_HOME"; then
    return 0
  fi
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  case "$identity" in
    *fm-supervise-daemon.sh*) return 0 ;;
  esac
  return 1
}

enable_afk() {
  date '+%s' > "$STATE/.afk"
}

fail_startup() {
  local msg=$1
  rm -f "$STATE/.afk" 2>/dev/null || true
  echo "$msg" >&2
  exit 1
}

reject_stale_afk_state() {
  local target=$1 composer_state
  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    fail_startup "error: afk entry refused because a prior away-mode escalation is still wedged; review $STATE/.subsuper-inject-wedged and clear the buffered supervisor state before retrying"
  fi
  composer_state=$(fm_tmux_composer_state "$target")
  if [ "$composer_state" = pending ]; then
    fail_startup "error: afk entry refused because the supervisor composer already has pending input; submit or clear it before retrying /afk"
  fi
}

remove_rejected_lock() {
  local rejected_pid=$1 lock_pid
  case "$rejected_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -e "$LOCK" ] || [ -L "$LOCK" ] || return 0
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$rejected_pid" ] || return 0
  fm_lock_remove_path "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
}

append_env_assignment() {
  local name=$1 val
  case "$name" in
    *[!A-Za-z0-9_]*|'') return 0 ;;
  esac
  eval "val=\${$name-}"
  printf ' %s=%s' "$name" "$(shell_quote "$val")"
}

tmux_target_resolves() {
  local pane
  pane=$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null) || return 1
  [ -n "$pane" ]
}

mkdir -p "$STATE"

if [ -s "$PIDFILE" ] && pidfile_alive; then
  enable_afk
  printf 'afk: daemon healthy pid=%s\n' "$(cat "$PIDFILE")"
  exit 0
fi
rejected_pid=$(cat "$PIDFILE" 2>/dev/null || true)
rm -f "$PIDFILE" 2>/dev/null || true
remove_rejected_lock "$rejected_pid"

command -v tmux >/dev/null 2>&1 || {
  fail_startup "error: tmux is required to start the afk supervise daemon"
}

target="${FM_SUPERVISOR_TARGET:-${TMUX_PANE:-firstmate:0}}"
if ! tmux_target_resolves "$target"; then
  fail_startup "error: supervisor target '$target' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET"
fi
reject_stale_afk_state "$target"

cmd="cd $(shell_quote "$FM_ROOT") && exec env"
cmd="$cmd PATH=$(shell_quote "$PATH")"
cmd="$cmd FM_ROOT=$(shell_quote "$FM_ROOT")"
cmd="$cmd FM_HOME=$(shell_quote "$FM_HOME")"
cmd="$cmd FM_STATE_OVERRIDE=$(shell_quote "$STATE")"
cmd="$cmd FM_SUPERVISOR_TARGET=$(shell_quote "$target")"

# Preserve explicit FM_* tuning from the caller. This keeps tests and operator
# overrides intact while still pinning the home, state, and target above.
for name in $(env | sed -n 's/=.*//p' | grep '^FM_' || true); do
  case "$name" in
    FM_ROOT|FM_HOME|FM_STATE_OVERRIDE|FM_SUPERVISOR_TARGET) continue ;;
  esac
  cmd="$cmd$(append_env_assignment "$name")"
done

cmd="$cmd $(shell_quote "$DAEMON") >>$(shell_quote "$LAUNCH_LOG") 2>&1"

enable_afk
tmux run-shell -b "$cmd" || {
  fail_startup "error: tmux failed to launch the afk supervise daemon"
}

start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$CONFIRM_TIMEOUT" ]; do
  if [ -s "$PIDFILE" ] && pidfile_alive; then
    printf 'afk: daemon started pid=%s target=%s\n' "$(cat "$PIDFILE")" "$target"
    exit 0
  fi
  sleep 0.2
done

echo "error: afk supervise daemon did not confirm startup within ${CONFIRM_TIMEOUT}s" >&2
if [ -s "$LAUNCH_LOG" ]; then
  echo "launch log:" >&2
  tail -40 "$LAUNCH_LOG" >&2
fi
rm -f "$STATE/.afk" 2>/dev/null || true
exit 1
