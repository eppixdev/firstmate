#!/usr/bin/env bash
# Ordinary-turn supervision sync for later captain interaction in an already
# started session.
# Drain queued wakes when they exist; otherwise run the same watcher
# liveness/tangle guard used elsewhere.
# Then surface the next currently-actionable parked/blocked gate so the very
# next supervision move is obvious before the turn ends or a reply is sent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

run_sync_core() {
  if [ -s "$FM_WAKE_QUEUE" ]; then
    "$SCRIPT_DIR/fm-wake-drain.sh"
  else
    "$SCRIPT_DIR/fm-guard.sh"
  fi
}

run_sync_core
status=$?
"$SCRIPT_DIR/fm-next-action.sh"
exit "$status"
