#!/usr/bin/env bash
# Mandatory immediate supervision pass after any captain-facing reply while work
# is still in flight.
# This deliberately reuses the ordinary turn-sync path so queued wakes are
# consumed the same way every other turn handles them, then it surfaces the next
# actionable parked/blocked gate if one is present.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/fm-turn-sync.sh"
