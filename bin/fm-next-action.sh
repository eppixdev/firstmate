#!/usr/bin/env bash
# Surface the next currently-actionable in-flight gate, if any.
# Read-only and side-effect free.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

matches=0
first_id=""
first_line=""

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta")
  id=${id%.meta}
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null || true)
  case "$line" in
    state:\ parked*|state:\ blocked*)
      matches=$((matches + 1))
      if [ -z "$first_id" ]; then
        first_id=$id
        first_line=$line
      fi
      ;;
  esac
done

[ "$matches" -gt 0 ] || exit 0

printf 'NEXT ACTION: %s - %s' "$first_id" "$first_line"
if [ "$matches" -gt 1 ]; then
  printf ' (+%s more parked/blocked)' "$((matches - 1))"
fi
printf '\n'
