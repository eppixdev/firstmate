#!/usr/bin/env bash
# tests/fm-afk-start-lifecycle-e2e.test.sh - AFK daemon startup ownership.
#
# Reproduces the July 7, 2026 failure mode: /afk was launched from an agent tool
# command, the daemon did not remain as the long-lived watcher owner, and a later
# done: status sat in the durable wake queue with no buffered escalation.
#
# The regression contract is two-part:
#   1. a direct nohup background child is vulnerable to launcher process-group
#      teardown, leaving .afk present but no daemon owner;
#   2. fm-afk-start.sh starts the daemon through the tmux server, so the daemon
#      survives launcher teardown and escalates a done: wake end to end.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
START="$ROOT/bin/fm-afk-start.sh"
WATCH="$ROOT/bin/fm-watch.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v setsid >/dev/null 2>&1 || { echo "skip: setsid not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-start-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
SUPERVISOR_PANE=
LOG_FILE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${STATE_DIR:-}" ]; then
    if [ -s "$STATE_DIR/.supervise-daemon.pid" ]; then
      kill "$(cat "$STATE_DIR/.supervise-daemon.pid")" 2>/dev/null || true
    fi
    rm -rf "$STATE_DIR" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-start-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\x1f'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
redraw() { printf '\r\033[K%s' "$_buf"; }
submit_line() {
  local _line=$_buf _class
  if [ "${_line:0:1}" = "$MARK" ]; then _class=injection; else _class=user; fi
  printf '%s\t%s\n' "$_line" "$_class" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1

TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

wait_for_pidfile() {
  local i=0
  while [ "$i" -lt 40 ]; do
    [ -s "$STATE_DIR/.supervise-daemon.pid" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

wait_for_digest() {
  local i=0
  while [ "$i" -lt 60 ]; do
    grep -q 'Supervisor escalate' "$LOG_FILE" 2>/dev/null && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

run_watcher_once() {
  local out="$STATE_DIR/watch.out"
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>"$STATE_DIR/watch.err" &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null || true; return 1; }
  wait "$pid" 2>/dev/null || true
  grep -F "signal: $STATE_DIR/fake-c1.status" "$out" >/dev/null 2>&1
}

reset_runtime_state() {
  rm -f "$STATE_DIR"/*.status \
        "$STATE_DIR"/.subsuper-* \
        "$STATE_DIR"/.supervise-daemon.pid \
        "$STATE_DIR"/.supervise-daemon.log \
        "$STATE_DIR"/.supervise-daemon.watcher.err \
        "$STATE_DIR"/.wake-queue* \
        "$STATE_DIR"/.watch.lock* \
        "$STATE_DIR"/.last-* \
        "$STATE_DIR"/.hash-* \
        "$STATE_DIR"/.count-* \
        "$STATE_DIR"/.stale-* \
        "$STATE_DIR"/.seen-* \
        "$STATE_DIR"/.heartbeat-streak \
        2>/dev/null || true
  : > "$LOG_FILE"
}

test_direct_nohup_can_leave_afk_without_daemon() {
  reset_runtime_state
  date '+%s' > "$STATE_DIR/.afk"
  # shellcheck disable=SC2016
  setsid bash -c '
    PATH="$1:$PATH" \
    FM_STATE_OVERRIDE="$2" \
    FM_SUPERVISOR_TARGET="$3" \
    FM_ESCALATE_BATCH_SECS=0 \
    FM_HOUSEKEEPING_TICK=1 \
    FM_POLL=1 \
    FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 \
    FM_STALE_ESCALATE_SECS=999999 \
      nohup "$4" >"$2/direct.out" 2>"$2/direct.err" &
    printf "%s\n" "$$" > "$2/launcher.pid"
    sleep 60
  ' _ "$TMUX_SHIM_DIR" "$STATE_DIR" "$SUPERVISOR_PANE" "$DAEMON" &
  local launcher=$!
  wait_for_pidfile || fail "direct daemon did not start"

  kill -TERM "-$launcher" 2>/dev/null || true
  sleep 1
  [ ! -s "$STATE_DIR/.supervise-daemon.pid" ] \
    || fail "direct daemon pid file survived launcher process-group teardown"

  printf 'done: shared scraper infrastructure hardening committed\n' > "$STATE_DIR/fake-c1.status"
  run_watcher_once || fail "watcher did not queue done status with afk active"
  [ -s "$STATE_DIR/.wake-queue" ] || fail "done wake was not preserved in wake queue"
  [ ! -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "dead direct daemon unexpectedly buffered an escalation"
  [ ! -s "$LOG_FILE" ] || fail "dead direct daemon unexpectedly injected a digest"
  pass "reproduced: direct nohup can leave afk active with done wake queued but no daemon escalation"
}

test_afk_start_survives_launcher_teardown_and_escalates_done() {
  reset_runtime_state
  # shellcheck disable=SC2016
  setsid bash -c '
    PATH="$1:$PATH" \
    FM_STATE_OVERRIDE="$2" \
    FM_SUPERVISOR_TARGET="$3" \
    FM_ESCALATE_BATCH_SECS=0 \
    FM_HOUSEKEEPING_TICK=1 \
    FM_POLL=1 \
    FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 \
    FM_INJECT_CONFIRM_SLEEP=0.2 \
    FM_INJECT_CONFIRM_RETRIES=5 \
    FM_STALE_ESCALATE_SECS=999999 \
      "$4" >"$2/start.out" 2>"$2/start.err"
    printf "%s\n" "$$" > "$2/start-launcher.pid"
    sleep 60
  ' _ "$TMUX_SHIM_DIR" "$STATE_DIR" "$SUPERVISOR_PANE" "$START" &
  local launcher=$!
  wait_for_pidfile || { cat "$STATE_DIR/start.err" >&2 2>/dev/null || true; fail "fm-afk-start did not start daemon"; }

  kill -TERM "-$launcher" 2>/dev/null || true
  sleep 1
  local daemon_pid
  daemon_pid=$(cat "$STATE_DIR/.supervise-daemon.pid" 2>/dev/null || true)
  if [ -z "$daemon_pid" ] || ! kill -0 "$daemon_pid" 2>/dev/null; then
    fail "fm-afk-start daemon did not survive launcher process-group teardown"
  fi

  printf 'done: shared scraper infrastructure hardening committed\n' > "$STATE_DIR/fake-c1.status"
  wait_for_digest || {
    echo "daemon log:" >&2; cat "$STATE_DIR/.supervise-daemon.log" >&2 2>/dev/null || true
    echo "watcher err:" >&2; cat "$STATE_DIR/.supervise-daemon.watcher.err" >&2 2>/dev/null || true
    fail "surviving daemon did not inject done escalation"
  }
  grep -q 'done: shared scraper infrastructure hardening committed' "$LOG_FILE" \
    || fail "injected digest did not include done status"
  pass "fm-afk-start survives launcher teardown and escalates a done status"
}

test_direct_nohup_can_leave_afk_without_daemon
test_afk_start_survives_launcher_teardown_and_escalates_done

echo "all afk start lifecycle tests passed"
