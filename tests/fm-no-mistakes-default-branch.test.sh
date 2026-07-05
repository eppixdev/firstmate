#!/usr/bin/env bash
# Regression coverage for the no-mistakes gate-mirror default-branch repair.
#
# The exact failure mode from the scout was a freshly initialized gate repo with
# no main refs at all. Review worktrees created from that mirror could not
# resolve `main`, which made review scope depend on downstream fallback logic.
# firstmate now repairs that invariant explicitly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-default-branch)

make_repo_with_origin() {
  local repo=$1 origin=$2 default_branch=${3:-main}
  git init --bare -q "$origin"
  git init -q "$repo"
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm initial
  git -C "$repo" branch -M "$default_branch"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -u origin "$default_branch" >/dev/null
  git --git-dir="$origin" symbolic-ref HEAD "refs/heads/$default_branch"
}

test_repairs_missing_gate_refs() {
  local repo origin gate out expected
  repo="$TMP_ROOT/repo"
  origin="$TMP_ROOT/origin.git"
  gate="$TMP_ROOT/gate.git"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"

  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/main; then
    fail "test fixture accidentally created gate main before repair"
  fi

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair failed"
  expected=$(git -C "$repo" rev-parse origin/main)
  [ "$(git --git-dir="$gate" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not seed refs/heads/main from origin/main"
  [ "$(git --git-dir="$gate" rev-parse refs/remotes/origin/main)" = "$expected" ] \
    || fail "repair did not seed refs/remotes/origin/main from origin/main"
  [ "$(git --git-dir="$gate" symbolic-ref HEAD)" = "refs/heads/main" ] \
    || fail "repair did not repoint gate HEAD to refs/heads/main"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the self-heal"
  pass "fm-no-mistakes-default-branch repairs an empty gate mirror"
}

test_noop_when_gate_is_current() {
  local repo origin gate out
  repo="$TMP_ROOT/repo-ok"
  origin="$TMP_ROOT/origin-ok.git"
  gate="$TMP_ROOT/gate-ok.git"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null || fail "initial repair failed"

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "second repair check failed"
  assert_contains "$out" "ok: no-mistakes gate mirror has main" \
    "healthy gate mirror did not report an ok status"
  pass "fm-no-mistakes-default-branch is a no-op when the gate mirror is current"
}

test_repairs_head_when_refs_are_already_seeded() {
  local repo origin gate out expected
  repo="$TMP_ROOT/repo-head-only"
  origin="$TMP_ROOT/origin-head-only.git"
  gate="$TMP_ROOT/gate-head-only.git"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  expected=$(git -C "$repo" rev-parse origin/main)
  git --git-dir="$gate" fetch --quiet "$repo" "refs/remotes/origin/main:refs/heads/main"
  git --git-dir="$gate" update-ref refs/remotes/origin/main "$expected"

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "head-only repair failed"
  [ "$(git --git-dir="$gate" symbolic-ref HEAD)" = "refs/heads/main" ] \
    || fail "repair did not repoint gate HEAD when refs were already current"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the HEAD-only self-heal"
  pass "fm-no-mistakes-default-branch repairs gate HEAD even when refs are current"
}

test_fails_without_no_mistakes_remote() {
  local repo origin err
  repo="$TMP_ROOT/repo-missing-remote"
  origin="$TMP_ROOT/origin-missing-remote.git"
  err="$TMP_ROOT/missing-remote.err"
  make_repo_with_origin "$repo" "$origin"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "repair succeeded without a no-mistakes remote"
  fi
  assert_grep "missing remote.no-mistakes.url" "$err" \
    "missing no-mistakes remote did not fail with a clear error"
  pass "fm-no-mistakes-default-branch fails fast when no-mistakes is not initialized"
}

test_uses_non_main_default_branch_without_origin_head() {
  local repo origin gate out expected
  repo="$TMP_ROOT/repo-develop"
  origin="$TMP_ROOT/origin-develop.git"
  gate="$TMP_ROOT/gate-develop.git"
  make_repo_with_origin "$repo" "$origin" develop
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair failed for develop"
  expected=$(git -C "$repo" rev-parse origin/develop)
  [ "$(git --git-dir="$gate" rev-parse refs/heads/develop)" = "$expected" ] \
    || fail "repair did not seed refs/heads/develop"
  [ "$(git --git-dir="$gate" symbolic-ref HEAD)" = "refs/heads/develop" ] \
    || fail "repair did not repoint gate HEAD to refs/heads/develop"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror develop, origin/develop, and HEAD" \
    "repair did not report the develop self-heal"
  pass "fm-no-mistakes-default-branch falls back to a single non-main branch"
}

test_repairs_missing_gate_refs
test_noop_when_gate_is_current
test_repairs_head_when_refs_are_already_seeded
test_fails_without_no_mistakes_remote
test_uses_non_main_default_branch_without_origin_head
