#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: healthy pid=<N> (beacon <age>s)             - a genuinely live+fresh watcher already held the lock
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started/healthy it exits zero; on FAILED it exits
# non-zero so the failure is loud and a caller can react. When an actionable wake
# fires, it exits with a dedicated non-zero status after printing the wake reason:
# background-task harnesses that only surface non-zero completions must treat a
# wake as noteworthy, or the queue fills while supervision silently goes stale.
# A healthy line means a live cycle already exists; do not churn extra no-op arms
# until that cycle fires.
#
# --keepalive: keep running after actionable wakes and immediately arm the next
# cycle. Some harnesses do not surface long-running background task completion
# back to firstmate automatically. In those environments the default one-shot
# arm can fire correctly, queue a wake, and then leave supervision down until a
# human sends the next prompt. Keepalive mode preserves the existing wake queue
# and stdout reason line, starts a fresh watcher cycle right away so firstmate
# is not blind between prompts, then reuses the ordinary turn-sync path to
# consume that queued wake and surface the next actionable gate.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
TURN_SYNC_BIN="${FM_WATCH_TURN_SYNC_BIN:-$SCRIPT_DIR/fm-turn-sync.sh}"
WATCH_LOCK="$STATE/.watch.lock"
KEEPALIVE_LOCK="$STATE/.watch.keepalive.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
WAKE_EXIT_STATUS=${FM_WATCH_WAKE_EXIT_STATUS:-10}

watch_lock_matches_pid() {
  local pid=$1
  fm_watcher_lock_matches_pid "$WATCH_LOCK" "$pid" "$WATCH" "$FM_HOME"
}

keepalive_lock_matches_pid() {
  local pid=$1
  fm_watcher_lock_matches_pid "$KEEPALIVE_LOCK" "$pid" "$0" "$FM_HOME"
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  fm_paths_equivalent "$lock_home" "$FM_HOME" || return 0
  fm_paths_equivalent "$lock_path" "$WATCH" || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

clear_stale_recorded_keepalive_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$KEEPALIVE_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$KEEPALIVE_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$KEEPALIVE_LOCK/pid-identity" 2>/dev/null || true)
  fm_paths_equivalent "$lock_home" "$FM_HOME" || return 0
  fm_paths_equivalent "$lock_path" "$0" || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$KEEPALIVE_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  local pid age
  HEALTHY_PID=
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  if fm_pid_alive "$pid" \
    && watch_lock_matches_pid "$pid" \
    && fm_watcher_beat_matches_pid "$BEAT" "$pid" "$WATCH" "$FM_HOME"; then
    HEALTHY_PID=$pid
    return 0
  fi
  fm_watcher_records_match "$WATCH_LOCK" "$BEAT" "$WATCH" "$FM_HOME" || return 1
  HEALTHY_PID=$pid
  return 0
}

legacy_healthy_watcher() {
  local pid age beat_pid beat_identity beat_path beat_home
  HEALTHY_PID=
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  watch_lock_matches_pid "$pid" || return 1
  [ -e "$BEAT" ] || return 1
  beat_pid=$(fm_watcher_beat_value "$BEAT" pid)
  beat_identity=$(fm_watcher_beat_value "$BEAT" 'pid-identity')
  beat_path=$(fm_watcher_beat_value "$BEAT" 'watcher-path')
  beat_home=$(fm_watcher_beat_value "$BEAT" 'fm-home')
  [ -z "$beat_pid" ] || return 1
  [ -z "$beat_identity" ] || return 1
  [ -z "$beat_path" ] || return 1
  [ -z "$beat_home" ] || return 1
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
  return 0
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

exit_with_wake() {
  local out=$1
  print_watch_output "$out"
  rm -f "$out" 2>/dev/null || true
  exit "$WAKE_EXIT_STATUS"
}

run_keepalive_turn_sync() {
  [ -e "$STATE/.afk" ] && return 0
  [ -x "$TURN_SYNC_BIN" ] || return 0
  "$TURN_SYNC_BIN" || true
}

mode=arm
keepalive=0
for arg in "$@"; do
  case "$arg" in
    ''|arm|--arm) mode=arm ;;
    --restart) mode=restart ;;
    --keepalive) keepalive=1 ;;
    *) echo "usage: $(basename "$0") [--keepalive] [--restart]" >&2; exit 2 ;;
  esac
done

if [ "$keepalive" -eq 1 ] && [ -z "${FM_WATCH_ARM_KEEPALIVE_CHILD:-}" ]; then
  keepalive_child=
  if ! fm_lock_try_acquire "$KEEPALIVE_LOCK"; then
    keepalive_pid=$(cat "$KEEPALIVE_LOCK/pid" 2>/dev/null || true)
    if ! keepalive_lock_matches_pid "$keepalive_pid"; then
      clear_stale_recorded_keepalive_lock
      if ! fm_lock_try_acquire "$KEEPALIVE_LOCK"; then
        keepalive_pid=$(cat "$KEEPALIVE_LOCK/pid" 2>/dev/null || true)
        if keepalive_lock_matches_pid "$keepalive_pid"; then
          exit 0
        fi
        exit 1
      fi
    else
      exit 0
    fi
  fi
  printf '%s\n' "$FM_HOME" > "$KEEPALIVE_LOCK/fm-home" || true
  printf '%s\n' "$0" > "$KEEPALIVE_LOCK/watcher-path" || true
  fm_pid_identity "${BASHPID:-$$}" > "$KEEPALIVE_LOCK/pid-identity" 2>/dev/null || true
  # shellcheck disable=SC2329
  cleanup_keepalive_child() {
    if [ -n "$keepalive_child" ] && fm_pid_alive "$keepalive_child"; then
      kill -TERM "$keepalive_child" 2>/dev/null || true
    fi
    fm_lock_release "$KEEPALIVE_LOCK" 2>/dev/null || true
  }
  trap 'cleanup_keepalive_child; exit 129' HUP
  trap 'cleanup_keepalive_child; exit 143' TERM INT

  first=1
  prelaunched=0
  while :; do
    if [ "$prelaunched" -eq 0 ]; then
      child_mode=--arm
      if [ "$first" -eq 1 ] && [ "$mode" = restart ]; then
        child_mode=--restart
      fi
      FM_WATCH_ARM_KEEPALIVE_CHILD=1 "$0" "$child_mode" &
      keepalive_child=$!
    fi
    first=0
    prelaunched=0
    wait "$keepalive_child"
    rc=$?
    keepalive_child=

    case "$rc" in
      "$WAKE_EXIT_STATUS")
        # The child already printed the wake reason and queued the durable wake.
        # Keep the next cycle live before draining through turn-sync so
        # supervision does not go blind while the queued wake is consumed.
        FM_WATCH_ARM_KEEPALIVE_CHILD=1 "$0" --arm &
        keepalive_child=$!
        prelaunched=1
        run_keepalive_turn_sync
        ;;
      0)
        # Another healthy watcher may own the singleton. Poll lightly until this
        # keepalive wrapper can take over a later lapsed cycle.
        sleep "${FM_WATCH_ARM_KEEPALIVE_IDLE_SLEEP:-5}"
        ;;
      *)
        echo "watcher: keepalive retry after arm exit $rc" >&2
        sleep "${FM_WATCH_ARM_KEEPALIVE_RETRY_SLEEP:-5}"
        ;;
    esac
  done
fi

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if watch_lock_matches_pid "$lock_pid"; then
    kill -TERM "$lock_pid" 2>/dev/null || true
    # Wait for it to actually exit before relaunching, so the fresh watcher
    # either takes a released lock or reclaims a now-dead-pid stale lock instead
    # of seeing the dying one as a live holder and no-opping.
    i=0
    while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
      sleep 0.1
      i=$((i + 1))
    done
  else
    clear_stale_recorded_watcher_lock
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - the singleton would no-op anyway. Report it honestly and return success.
# (--restart skips this: it just stopped this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && { healthy_watcher || legacy_healthy_watcher; }; then
  report_healthy
  exit 0
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
"$WATCH" >"$child_out" &
child=$!
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
        exit_with_wake "$child_out"
      fi
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit "$rc"
    fi
    # Another watcher won the singleton; our child stood down. Report the live one.
    report_healthy
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if legacy_healthy_watcher && [ "$HEALTHY_PID" != "$child" ]; then
    report_healthy
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      exit_with_wake "$child_out"
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
