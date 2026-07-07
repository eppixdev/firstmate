#!/usr/bin/env bash
# tests/fm-lifecycle-lib.test.sh - supervisor-owned lifecycle reconciliation:
# durable PR-ready discovery, merged-task cleanup, scout completion cleanup, and
# loud structured cleanup failure when teardown cannot finish.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIFECYCLE_LIB="$ROOT/bin/fm-lifecycle-lib.sh"
if [ -z "${FM_TEST_LIFECYCLE_SOURCED:-}" ]; then
  export FM_TEST_LIFECYCLE_SOURCED=1
  # shellcheck source=bin/fm-lifecycle-lib.sh
  . "$LIFECYCLE_LIB"
fi

TMP_ROOT=$(fm_test_tmproot fm-lifecycle-lib-tests)

make_case() {
  local name=$1 id=${2:-task-x1} kind=${3:-ship} mode=${4:-no-mistakes} dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/data/$id" "$dir/fakebin" "$dir/wt" "$dir/project"
  fm_write_meta "$dir/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=$kind" \
    "mode=$mode"

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FM_TEST_GH_AXI_LOG:?}"
case "${1:-} ${2:-}" in
  "pr view")
    if [ "${3:-}" = "--json" ]; then
      printf '%s\n' "${FM_TEST_GH_AXI_PR_VIEW_CURRENT:-}"
      exit 0
    fi
    printf '%s\n' "${FM_TEST_GH_AXI_PR_VIEW_TARGET:-}"
    exit 0
    ;;
  "issue close")
    [ "${FM_TEST_GH_AXI_ISSUE_CLOSE_FAIL:-0}" = 0 ] || exit 1
    exit 0
    ;;
esac
exit 0
SH

  cat > "$dir/pr-check.sh" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
url=$2
printf '%s\t%s\n' "$id" "$url" >> "${FM_TEST_PR_CHECK_LOG:?}"
echo "pr=$url" >> "${FM_STATE_OVERRIDE:?}/$id.meta"
: > "${FM_STATE_OVERRIDE:?}/$id.check.sh"
SH

  cat > "$dir/teardown.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1" >> "${FM_TEST_TEARDOWN_LOG:?}"
[ "${FM_TEST_TEARDOWN_FAIL:-0}" = 0 ] || {
  echo "REFUSED: teardown failed for $1" >&2
  exit 1
}
rm -f "${FM_STATE_OVERRIDE:?}/$1.meta" "${FM_STATE_OVERRIDE:?}/$1.status"
SH

  chmod +x "$fakebin/gh-axi" "$dir/pr-check.sh" "$dir/teardown.sh"
  printf '%s\n' "$dir"
}

test_discovers_pr_ready_and_arms_poll() {
  local dir state data id
  id=task-x1
  dir=$(make_case pr-ready "$id" ship no-mistakes)
  state="$dir/state"
  data="$dir/data"
  : > "$state/$id.turn-ended"
  : > "$dir/gh-axi.log"
  : > "$dir/pr-check.log"
  : > "$dir/teardown.log"

  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_CURRENT=$'OPEN\thttps://github.com/example/repo/pull/9' \
    fm_lifecycle_reconcile watcher "$state"

  assert_grep 'PR ready https://github.com/example/repo/pull/9 (supervisor)' "$state/$id.status" \
    "reconcile did not write a durable PR-ready status"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$state/$id.meta" \
    "reconcile did not record pr= through pr-check"
  assert_present "$state/$id.check.sh" "reconcile did not arm the merged-PR poll"
  [ ! -e "$(fm_lifecycle_pending_path "$state" "$id")" ] \
    || fail "PR-ready discovery should not enqueue cleanup"
  pass "lifecycle reconcile discovers an open PR, records it durably, and arms merge polling"
}

test_merged_issue_closes_issue_then_tears_down_after_seen() {
  local dir state data id trigger pending
  id=issue-30-price-history-semantics
  dir=$(make_case merged-cleanup "$id" ship no-mistakes)
  state="$dir/state"
  data="$dir/data"
  printf 'pr=https://github.com/example/repo/pull/46\n' >> "$state/$id.meta"
  : > "$dir/gh-axi.log"
  : > "$dir/pr-check.log"
  : > "$dir/teardown.log"

  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_TARGET=$'MERGED\thttps://github.com/example/repo/pull/46' \
    fm_lifecycle_reconcile watcher "$state"

  trigger='merged: https://github.com/example/repo/pull/46 (supervisor)'
  assert_grep "$trigger" "$state/$id.status" \
    "reconcile did not write the durable merged status"
  pending=$(fm_lifecycle_pending_path "$state" "$id")
  assert_present "$pending" "reconcile did not mark merged cleanup pending"
  [ ! -s "$dir/teardown.log" ] || fail "cleanup ran before the merged status was surfaced"

  printf '%s' "$trigger" > "$state/.hb-surfaced-$(fm_lifecycle_key "$id")"
  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_TARGET=$'MERGED\thttps://github.com/example/repo/pull/46' \
    fm_lifecycle_reconcile watcher "$state"

  grep -qxF 'issue close 30 --repo example/repo' "$dir/gh-axi.log" \
    || fail "merged cleanup did not close the matching GitHub issue"
  grep -qxF "$id" "$dir/teardown.log" \
    || fail "merged cleanup did not trigger teardown after the status was surfaced"
  assert_absent "$pending" "cleanup pending marker survived a successful teardown"
  pass "merged reconcile closes the linked issue and tears down only after the merged status was surfaced"
}

test_scout_report_tears_down_after_seen() {
  local dir state data id trigger pending
  id=gdf-next-issue-review
  dir=$(make_case scout-cleanup "$id" scout no-mistakes)
  state="$dir/state"
  data="$dir/data"
  printf 'report\n' > "$data/$id/report.md"
  : > "$state/$id.turn-ended"
  : > "$dir/gh-axi.log"
  : > "$dir/pr-check.log"
  : > "$dir/teardown.log"

  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
    fm_lifecycle_reconcile watcher "$state"

  trigger='done: scout report written data/gdf-next-issue-review/report.md (supervisor)'
  assert_grep "$trigger" "$state/$id.status" \
    "scout reconcile did not write the durable report-complete status"
  pending=$(fm_lifecycle_pending_path "$state" "$id")
  assert_present "$pending" "scout reconcile did not mark cleanup pending"
  [ ! -s "$dir/teardown.log" ] || fail "scout cleanup ran before the report-complete status was surfaced"

  printf '%s' "$trigger" > "$state/.hb-surfaced-$(fm_lifecycle_key "$id")"
  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
    fm_lifecycle_reconcile watcher "$state"

  grep -qxF "$id" "$dir/teardown.log" \
    || fail "scout reconcile did not trigger teardown after the report status was surfaced"
  assert_absent "$pending" "scout cleanup marker survived a successful teardown"
  pass "scout reconcile tears down a completed report only after the status was surfaced"
}

test_cleanup_failure_is_durable_and_non_repeating() {
  local dir state data id trigger failed
  id=task-x2
  dir=$(make_case cleanup-failure "$id" ship no-mistakes)
  state="$dir/state"
  data="$dir/data"
  printf 'pr=https://github.com/example/repo/pull/52\n' >> "$state/$id.meta"
  : > "$dir/gh-axi.log"
  : > "$dir/pr-check.log"
  : > "$dir/teardown.log"

  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_TARGET=$'MERGED\thttps://github.com/example/repo/pull/52' \
  FM_TEST_TEARDOWN_FAIL=1 \
    fm_lifecycle_reconcile watcher "$state"

  trigger='merged: https://github.com/example/repo/pull/52 (supervisor)'
  printf '%s' "$trigger" > "$state/.hb-surfaced-$(fm_lifecycle_key "$id")"
  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_TARGET=$'MERGED\thttps://github.com/example/repo/pull/52' \
  FM_TEST_TEARDOWN_FAIL=1 \
    fm_lifecycle_reconcile watcher "$state"

  assert_grep 'failed: cleanup task-x2: REFUSED: teardown failed for task-x2' "$state/$id.status" \
    "cleanup failure was not written as a durable failed: status"
  failed=$(fm_lifecycle_failed_path "$state" "$id")
  assert_present "$failed" "cleanup failure marker was not recorded"

  PATH="$dir/fakebin:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_LIFECYCLE_PR_CHECK_BIN="$dir/pr-check.sh" \
  FM_LIFECYCLE_TEARDOWN_BIN="$dir/teardown.sh" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_TEST_PR_CHECK_LOG="$dir/pr-check.log" \
  FM_TEST_TEARDOWN_LOG="$dir/teardown.log" \
  FM_TEST_GH_AXI_PR_VIEW_TARGET=$'MERGED\thttps://github.com/example/repo/pull/52' \
  FM_TEST_TEARDOWN_FAIL=1 \
    fm_lifecycle_reconcile watcher "$state"

  [ "$(wc -l < "$dir/teardown.log" | tr -d ' ')" -eq 1 ] \
    || fail "cleanup retried after recording a durable failure marker"
  pass "cleanup failure becomes a durable failed: status and does not hot-loop retries"
}

test_discovers_pr_ready_and_arms_poll
test_merged_issue_closes_issue_then_tears_down_after_seen
test_scout_report_tears_down_after_seen
test_cleanup_failure_is_durable_and_non_repeating
