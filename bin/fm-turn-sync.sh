#!/usr/bin/env bash
# Ordinary-turn supervision sync for later captain interaction in an already
# started session. Drain queued wakes when they exist; otherwise run the same
# watcher liveness/tangle guard used elsewhere.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ -s "$FM_WAKE_QUEUE" ]; then
  exec "$SCRIPT_DIR/fm-wake-drain.sh"
fi

exec "$SCRIPT_DIR/fm-guard.sh"
