#!/usr/bin/env bash
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TURN_SYNC="$ROOT/bin/fm-turn-sync.sh"
POST_REPLY="$ROOT/bin/fm-post-reply-supervise.sh"
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

test_turn_sync_surfaces_next_actionable_gate() {
  local dir state out fakebin
  dir=$(make_case turn-sync-next-action)
  state="$dir/state"
  out="$dir/out"
  fakebin="$dir/fakebin"

  printf 'window=test:fm-task\nkind=ship\n' > "$state/task.meta"

  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review' \
    "$TURN_SYNC" > "$out" 2>&1 || fail "turn sync should succeed when surfacing a parked gate"

  assert_contains "$(cat "$out")" "NEXT ACTION: task - state: parked" "turn sync did not surface the next actionable gate"
  pass "turn sync surfaces the next actionable parked gate"
}

test_post_reply_supervise_reuses_turn_sync_path() {
  local dir state out fakebin
  dir=$(make_case post-reply-supervise)
  state="$dir/state"
  out="$dir/out"
  fakebin="$dir/fakebin"

  printf 'window=test:fm-task\nkind=ship\n' > "$state/task.meta"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "append wake failed"

  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: blocked · source: run-step · parked at review' \
    "$POST_REPLY" > "$out" 2>&1 || fail "post-reply supervision should succeed"

  grep "$(printf '\tsignal\ttask.status\t')" "$out" >/dev/null || fail "post-reply supervision did not drain through turn-sync"
  assert_contains "$(cat "$out")" "NEXT ACTION: task - state: blocked" "post-reply supervision did not surface the next blocked gate"
  [ ! -s "$state/.wake-queue" ] || fail "post-reply supervision did not empty the wake queue"
  pass "post-reply supervision drains wakes and surfaces the next gate"
}

test_post_reply_supervise_peeks_active_pane_when_status_is_unchanged() {
  local dir state out fakebin capture
  dir=$(make_case post-reply-pane-reply)
  state="$dir/state"
  out="$dir/out"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"

  printf '%s\n' \
    'validation still running' \
    'I found the monitoring gap in fm-post-reply-supervise.sh' > "$capture"
  printf 'window=test:fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: validation still running\n' > "$state/task.status"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_FAKE_TMUX_CAPTURE="$capture" "$POST_REPLY" > "$out" 2>&1 || fail "post-reply supervision should succeed for a live validating crew"

  assert_contains "$(cat "$out")" "PANE REPLY: task - I found the monitoring gap in fm-post-reply-supervise.sh" \
    "post-reply supervision did not surface the pane-only reply"
  pass "post-reply supervision peeks the live pane when status is unchanged"
}

test_turn_sync_drains_pending_queue
test_turn_sync_runs_guard_when_queue_empty
test_turn_sync_surfaces_next_actionable_gate
test_post_reply_supervise_reuses_turn_sync_path
test_post_reply_supervise_peeks_active_pane_when_status_is_unchanged
