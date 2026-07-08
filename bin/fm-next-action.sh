#!/usr/bin/env bash
# Surface the next currently-actionable in-flight follow-up, if any.
# Priority order:
# 1. terminal crew states that still need captain follow-through, such as done
#    before teardown;
# 2. parked or blocked gates that need a steer or decision.
# Read-only and side-effect free.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

terminal_matches=0
terminal_first_id=""
terminal_first_line=""
gate_matches=0
gate_first_id=""
gate_first_line=""

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta")
  id=${id%.meta}
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null || true)
  case "$line" in
    state:\ done*|state:\ failed*)
      terminal_matches=$((terminal_matches + 1))
      if [ -z "$terminal_first_id" ]; then
        terminal_first_id=$id
        terminal_first_line=$line
      fi
      ;;
    state:\ parked*|state:\ blocked*)
      gate_matches=$((gate_matches + 1))
      if [ -z "$gate_first_id" ]; then
        gate_first_id=$id
        gate_first_line=$line
      fi
      ;;
  esac
done

if [ "$terminal_matches" -gt 0 ]; then
  printf 'NEXT ACTION: %s - %s' "$terminal_first_id" "$terminal_first_line"
  if [ "$terminal_matches" -gt 1 ]; then
    printf ' (+%s more terminal follow-up)' "$((terminal_matches - 1))"
  fi
  printf '\n'
  exit 0
fi

[ "$gate_matches" -gt 0 ] || exit 0

printf 'NEXT ACTION: %s - %s' "$gate_first_id" "$gate_first_line"
if [ "$gate_matches" -gt 1 ]; then
  printf ' (+%s more parked/blocked)' "$((gate_matches - 1))"
fi
printf '\n'
