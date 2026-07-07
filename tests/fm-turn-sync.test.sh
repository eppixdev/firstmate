#!/usr/bin/env bash
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TURN_SYNC="$ROOT/bin/fm-turn-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-turn-sync-tests)

test_turn_sync_drains_pending_queue() {
  local dir state out
  dir=$(make_case turn-sync-drain)
  state="$dir/state"
  out="$dir/out"

  append_wake "$state" signal task.status "signal: $state/task.status" || fail "append wake failed"

  FM_STATE_OVERRIDE="$state" "$TURN_SYNC" > "$out" 2>&1 || fail "turn sync should succeed when draining queue"

  grep "$(printf '\tsignal\ttask.status\t')" "$out" >/dev/null || fail "turn sync did not print the drained wake"
  [ ! -s "$state/.wake-queue" ] || fail "turn sync did not empty the wake queue"
  pass "turn sync drains pending queue records"
}

test_turn_sync_runs_guard_when_queue_empty() {
  local dir state out
  dir=$(make_case turn-sync-guard)
  state="$dir/state"
  out="$dir/out"

  printf 'window=test:fm-task\nkind=ship\n' > "$state/task.meta"

  FM_STATE_OVERRIDE="$state" "$TURN_SYNC" > "$out" 2>&1 || fail "turn sync should succeed when guard warns"

  assert_contains "$(cat "$out")" "WATCHER DOWN - SUPERVISION IS OFF" "turn sync did not run guard when queue empty"
  pass "turn sync falls back to guard when queue is empty"
}

test_turn_sync_drains_pending_queue
test_turn_sync_runs_guard_when_queue_empty
