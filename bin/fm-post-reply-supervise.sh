#!/usr/bin/env bash
# Mandatory immediate supervision pass after any captain-facing reply while work
# is still in flight.
# This deliberately reuses the ordinary turn-sync path so queued wakes are
# consumed the same way every other turn handles them, then it surfaces the next
# actionable parked/blocked gate if one is present.
# If a crew is still provably active and its status log did not advance during
# that pass, also do one bounded pane peek so a pane-only reply is not missed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
FM_SEND_BIN="${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
FM_POST_REPLY_PEEK_LINES="${FM_POST_REPLY_PEEK_LINES:-40}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

status_signature() {  # <status-file>
  local file=$1 size mtime
  [ -e "$file" ] || { printf 'absent\n'; return 0; }
  size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$file" 2>/dev/null || true)
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null || true)
  fi
  printf '%s:%s\n' "${size:-?}" "${mtime:-?}"
}

crew_is_still_active() {  # <id>
  local line
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null || true)
  case "$line" in
    state:\ working*"source: run-step"*|state:\ working*"source: pane"*) return 0 ;;
    *) return 1 ;;
  esac
}

trim_line() {  # <line>
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

run_head_sync_marker() {  # <id>
  printf '%s/.run-head-sync-%s' "$STATE" "$1"
}

extract_run_head_token() {  # <crew-state line> <token>
  printf '%s\n' "$1" | sed -n "s/.*$2=\\([^ ·]*\\).*/\\1/p" | head -1
}

maybe_send_run_head_sync() {  # <id> <crew-state line>
  local id=$1 line=$2 run_head local_head marker sent
  case "$line" in
    state:\ blocked*"source: run-step"*"run-head drift:"*) ;;
    *)
      rm -f "$(run_head_sync_marker "$id")"
      return 0
      ;;
  esac
  run_head=$(extract_run_head_token "$line" "run-head")
  local_head=$(extract_run_head_token "$line" "local-head")
  [ -n "$run_head" ] || return 0
  marker=$(run_head_sync_marker "$id")
  [ "$(cat "$marker" 2>/dev/null || true)" = "$run_head" ] && return 0
  sent="no-mistakes advanced the run head to $run_head while your local checkout is still at $local_head. Sync to the current run head with a safe fast-forward now: git fetch no-mistakes && git merge --ff-only $run_head. If the fast-forward refuses, inspect the checkout and then continue the fix review from the updated branch."
  "$FM_SEND_BIN" "fm-$id" "$sent" >/dev/null 2>&1 || return 0
  printf '%s\n' "$run_head" > "$marker"
  printf 'SYNC STEER: %s - local %s behind run head %s\n' "$id" "${local_head:-unknown}" "$run_head"
}

meaningful_pane_line() {  # stdin: pane capture
  local line trimmed
  while IFS= read -r line; do
    trimmed=$(trim_line "$line")
    [ -n "$trimmed" ] || continue
    printf '%s' "$trimmed" | grep -qiE 'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel' && continue
    printf '%s' "$trimmed" | grep -q '[[:alnum:]]' || continue
    printf '%s\n' "$trimmed"
    return 0
  done < <(awk '{ lines[++n]=$0 } END { for (i = n; i >= 1; i--) print lines[i] }')
  return 1
}

SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-post-reply.XXXXXX")
trap 'rm -rf "$SNAPSHOT_DIR"' EXIT

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta")
  id=${id%.meta}
  status_signature "$STATE/$id.status" > "$SNAPSHOT_DIR/$id.sig"
done

"$SCRIPT_DIR/fm-turn-sync.sh"
status=$?

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta")
  id=${id%.meta}
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null || true)
  maybe_send_run_head_sync "$id" "$line"
  case "$line" in
    state:\ working*"source: run-step"*|state:\ working*"source: pane"*) ;;
    *) continue ;;
  esac
  before=$(cat "$SNAPSHOT_DIR/$id.sig" 2>/dev/null || printf 'absent\n')
  after=$(status_signature "$STATE/$id.status")
  [ "$before" = "$after" ] || continue

  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  expected_label="fm-$id"
  pane=$(fm_backend_capture "$backend" "$target" "$FM_POST_REPLY_PEEK_LINES" "$expected_label" 2>/dev/null || true)
  [ -n "$pane" ] || continue
  line=$(printf '%s\n' "$pane" | meaningful_pane_line || true)
  [ -n "$line" ] || continue
  printf 'PANE REPLY: %s - %s\n' "$id" "$line"
done

exit "$status"
