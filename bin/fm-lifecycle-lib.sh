#!/usr/bin/env bash
# Shared supervisor-owned lifecycle reconciliation.
#
# Why this exists:
#   - a ship task can finish and open a PR without ever writing a durable status
#     line, leaving supervision with only a turn-end or stale-pane wake;
#   - a merged PR can be noticed transiently through a check wake, but without a
#     durable supervisor-owned record the captain may miss it and cleanup may not
#     run;
#   - a scout can finish by writing its report, yet still linger until a manual
#     teardown.
#
# This library moves those lifecycle facts under supervisor control. It discovers
# durable completion facts from task metadata, PR state, and scout reports,
# writes supervisor-owned status lines, and then drives teardown only AFTER the
# surfaced marker for that status proves the captain-facing supervisor has seen
# it. Cleanup failures are turned into durable failed: status lines instead of
# leaving a silent half-cleaned task behind.

_FM_LIFECYCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_LIFECYCLE_DIR="."
_FM_LIFECYCLE_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_LIFECYCLE_DIR/.." && pwd)}"
_FM_LIFECYCLE_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$_FM_LIFECYCLE_ROOT}}"
FM_LIFECYCLE_PR_CHECK_BIN="${FM_LIFECYCLE_PR_CHECK_BIN:-$_FM_LIFECYCLE_ROOT/bin/fm-pr-check.sh}"
FM_LIFECYCLE_TEARDOWN_BIN="${FM_LIFECYCLE_TEARDOWN_BIN:-$_FM_LIFECYCLE_ROOT/bin/fm-teardown.sh}"

fm_lifecycle_data_root() {
  printf '%s' "${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$_FM_LIFECYCLE_ROOT}}/data}"
}

fm_lifecycle_key() {
  printf '%s' "$1" | tr ':/.' '___'
}

fm_lifecycle_meta_get() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_lifecycle_status_append() {  # <status-file> <line>
  local status_file=$1 line=$2
  mkdir -p "$(dirname "$status_file")"
  grep -qxF "$line" "$status_file" 2>/dev/null && return 1
  printf '%s\n' "$line" >> "$status_file"
}

fm_lifecycle_pending_path() {  # <state> <id>
  printf '%s/.lifecycle-cleanup-%s' "$1" "$(fm_lifecycle_key "$2")"
}

fm_lifecycle_failed_path() {  # <state> <id>
  printf '%s/.lifecycle-cleanup-failed-%s' "$1" "$(fm_lifecycle_key "$2")"
}

fm_lifecycle_seen_path() {  # <mode> <state> <id>
  case "$1" in
    daemon)  printf '%s/.subsuper-seen-status-%s' "$2" "$(fm_lifecycle_key "$3")" ;;
    watcher) printf '%s/.hb-surfaced-%s' "$2" "$(fm_lifecycle_key "$3")" ;;
    *)       return 1 ;;
  esac
}

fm_lifecycle_status_seen() {  # <mode> <state> <id> <line>
  local seen
  seen=$(fm_lifecycle_seen_path "$1" "$2" "$3") || return 1
  [ "$(cat "$seen" 2>/dev/null || true)" = "$4" ]
}

fm_lifecycle_set_pending_cleanup() {  # <state> <id> <kind> <trigger-line>
  local state=$1 id=$2 kind=$3 trigger=$4 pending failed current_kind current_trigger
  pending=$(fm_lifecycle_pending_path "$state" "$id")
  failed=$(fm_lifecycle_failed_path "$state" "$id")
  if [ -r "$pending" ]; then
    IFS="$(printf '\t')" read -r current_kind current_trigger < "$pending" || true
    if [ "$current_kind" = "$kind" ] && [ "$current_trigger" = "$trigger" ]; then
      return 0
    fi
  fi
  printf '%s\t%s\n' "$kind" "$trigger" > "$pending"
  rm -f "$failed"
}

fm_lifecycle_open_pr_url() {  # <worktree>
  local wt=$1 out state url
  [ -d "$wt" ] || return 1
  out=$(cd "$wt" && gh-axi pr view --json state,url -q '.state + "\t" + .url' 2>/dev/null) || return 1
  state=${out%%$'\t'*}
  url=${out#*$'\t'}
  [ "$url" != "$out" ] || return 1
  case "$state" in
    OPEN|open) printf '%s\n' "$url" ;;
    *) return 1 ;;
  esac
}

fm_lifecycle_pr_is_merged() {  # <worktree> <pr-url>
  local wt=$1 pr_url=$2 out state url
  [ -d "$wt" ] || return 1
  [ -n "$pr_url" ] || return 1
  out=$(cd "$wt" && gh-axi pr view "$pr_url" --json state,url -q '.state + "\t" + .url' 2>/dev/null) || return 1
  state=${out%%$'\t'*}
  url=${out#*$'\t'}
  [ "$url" != "$out" ] || return 1
  case "$state" in
    MERGED|merged) printf '%s\n' "$url" ;;
    *) return 1 ;;
  esac
}

fm_lifecycle_issue_ref() {  # <task-id> <pr-url>
  local id=$1 pr_url=$2 issue owner repo
  [[ "$id" =~ ^issue-([0-9]+)- ]] || return 1
  issue=${BASH_REMATCH[1]}
  [[ "$pr_url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/[0-9]+/?$ ]] || return 1
  owner=${BASH_REMATCH[1]}
  repo=${BASH_REMATCH[2]}
  printf '%s\t%s/%s\n' "$issue" "$owner" "$repo"
  return 0
}

fm_lifecycle_compact_line() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

fm_lifecycle_cleanup_failure() {  # <state> <id> <message>
  local state=$1 id=$2 message=$3 status_file failed_file line
  status_file="$state/$id.status"
  failed_file=$(fm_lifecycle_failed_path "$state" "$id")
  line="failed: cleanup $id: $message"
  if [ ! -r "$failed_file" ] || [ "$(cat "$failed_file" 2>/dev/null || true)" != "$line" ]; then
    fm_lifecycle_status_append "$status_file" "$line" || true
    printf '%s\n' "$line" > "$failed_file"
  fi
}

fm_lifecycle_try_cleanup() {  # <mode> <state> <id> <meta>
  local mode=$1 state=$2 id=$3 meta=$4 pending failed status_file kind trigger
  local issue_ref issue repo out summary
  pending=$(fm_lifecycle_pending_path "$state" "$id")
  [ -r "$pending" ] || return 0
  IFS="$(printf '\t')" read -r kind trigger < "$pending" || return 0
  [ -n "$kind" ] || return 0
  [ -n "$trigger" ] || return 0
  fm_lifecycle_status_seen "$mode" "$state" "$id" "$trigger" || return 0
  failed=$(fm_lifecycle_failed_path "$state" "$id")
  if [ -r "$failed" ] && [ -n "$(cat "$failed" 2>/dev/null || true)" ]; then
    return 0
  fi

  if [ "$kind" = merged ]; then
    issue_ref=$(fm_lifecycle_issue_ref "$id" "$(fm_lifecycle_meta_get "$meta" pr)" || true)
    if [ -n "$issue_ref" ]; then
      IFS="$(printf '\t')" read -r issue repo <<EOF
$issue_ref
EOF
      if ! gh-axi issue close "$issue" --repo "$repo" >/dev/null 2>&1; then
        fm_lifecycle_cleanup_failure "$state" "$id" "GitHub issue #$issue was not closed"
        return 0
      fi
    fi
  fi

  if out=$("$FM_LIFECYCLE_TEARDOWN_BIN" "$id" 2>&1); then
    rm -f "$pending" "$failed"
    return 0
  fi

  summary=$(fm_lifecycle_compact_line "$out")
  [ -n "$summary" ] || summary="teardown failed"
  fm_lifecycle_cleanup_failure "$state" "$id" "$summary"
}

fm_lifecycle_reconcile_task() {  # <mode> <state> <meta-file>
  local mode=$1 state=$2 meta=$3 id kind task_mode wt pr_url status_file line report
  id=$(basename "$meta" .meta)
  kind=$(fm_lifecycle_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  task_mode=$(fm_lifecycle_meta_get "$meta" mode)
  [ -n "$task_mode" ] || task_mode=no-mistakes
  wt=$(fm_lifecycle_meta_get "$meta" worktree)
  pr_url=$(fm_lifecycle_meta_get "$meta" pr)
  status_file="$state/$id.status"

  if [ "$kind" = ship ] && [ "$task_mode" != local-only ] && [ -z "$pr_url" ] && [ -e "$state/$id.turn-ended" ]; then
    if pr_url=$(fm_lifecycle_open_pr_url "$wt"); then
      "$FM_LIFECYCLE_PR_CHECK_BIN" "$id" "$pr_url" >/dev/null 2>&1 || true
      line="PR ready $pr_url (supervisor)"
      fm_lifecycle_status_append "$status_file" "$line" || true
    fi
    pr_url=$(fm_lifecycle_meta_get "$meta" pr)
  fi

  if [ "$kind" = ship ] && [ -n "$pr_url" ]; then
    if pr_url=$(fm_lifecycle_pr_is_merged "$wt" "$pr_url"); then
      line="merged: $pr_url (supervisor)"
      fm_lifecycle_status_append "$status_file" "$line" || true
      fm_lifecycle_set_pending_cleanup "$state" "$id" merged "$line"
    fi
  fi

  if [ "$kind" = scout ] && [ -e "$state/$id.turn-ended" ]; then
    report="$(fm_lifecycle_data_root)/$id/report.md"
    if [ -f "$report" ]; then
      line="done: scout report written data/$id/report.md (supervisor)"
      fm_lifecycle_status_append "$status_file" "$line" || true
      fm_lifecycle_set_pending_cleanup "$state" "$id" scout "$line"
    fi
  fi

  fm_lifecycle_try_cleanup "$mode" "$state" "$id" "$meta"
}

fm_lifecycle_reconcile() {  # <mode> <state>
  local mode=$1 state=$2 meta
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    fm_lifecycle_reconcile_task "$mode" "$state" "$meta"
  done
}
