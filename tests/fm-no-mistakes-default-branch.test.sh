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

test_prefers_single_remote_branch_over_local_main_fallback() {
  local repo origin gate out expected
  repo="$TMP_ROOT/repo-develop-with-main"
  origin="$TMP_ROOT/origin-develop-with-main.git"
  gate="$TMP_ROOT/gate-develop-with-main.git"
  make_repo_with_origin "$repo" "$origin" develop
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  git -C "$repo" branch main

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair preferred stray local main"
  expected=$(git -C "$repo" rev-parse origin/develop)
  [ "$(git --git-dir="$gate" rev-parse refs/heads/develop)" = "$expected" ] \
    || fail "repair did not prefer the single origin/develop branch"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror develop, origin/develop, and HEAD" \
    "repair did not report the develop self-heal when local main existed"
  pass "fm-no-mistakes-default-branch prefers remote branch evidence over local main"
}

test_fails_closed_for_lone_local_tracking_branch_when_origin_head_is_missing() {
  local repo origin gate peer err
  repo="$TMP_ROOT/repo-develop-and-remote-topic"
  origin="$TMP_ROOT/origin-develop-and-remote-topic.git"
  gate="$TMP_ROOT/gate-develop-and-remote-topic.git"
  peer="$TMP_ROOT/repo-develop-and-remote-topic-peer"
  err="$TMP_ROOT/repo-develop-and-remote-topic.err"
  make_repo_with_origin "$repo" "$origin" develop
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  git clone -q "$origin" "$peer"
  git -C "$peer" config user.name 'Firstmate Tests'
  git -C "$peer" config user.email 'tests@example.invalid'
  git -C "$peer" checkout -q -b topic
  printf 'topic\n' >> "$peer/README.md"
  git -C "$peer" commit -qam topic
  git -C "$peer" push -u origin topic >/dev/null
  git -C "$repo" fetch -q origin topic
  git -C "$repo" checkout -q --detach
  git -C "$repo" branch -D develop >/dev/null
  git -C "$repo" remote set-head origin --delete >/dev/null 2>&1 || true
  git -C "$repo" remote set-url origin "$TMP_ROOT/missing-lone-local-origin.git"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "default-branch repair guessed from a lone local tracking branch"
  fi
  assert_grep "cannot determine default branch" "$err" \
    "lone local tracking branch state did not fail with a clear error"
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/develop; then
    fail "lone local tracking branch repair seeded refs/heads/develop"
  fi
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/topic; then
    fail "lone local tracking branch repair seeded refs/heads/topic"
  fi
  pass "fm-no-mistakes-default-branch fails closed for a lone local tracking branch"
}

test_fails_closed_for_single_fetched_topic_when_origin_head_is_missing() {
  local seed repo origin gate err
  seed="$TMP_ROOT/repo-single-topic-seed"
  repo="$TMP_ROOT/repo-single-topic"
  origin="$TMP_ROOT/origin-single-topic.git"
  gate="$TMP_ROOT/gate-single-topic.git"
  err="$TMP_ROOT/repo-single-topic.err"
  make_repo_with_origin "$seed" "$origin" main
  git -C "$seed" checkout -q -b topic
  printf 'topic\n' >> "$seed/README.md"
  git -C "$seed" commit -qam topic
  git -C "$seed" push -u origin topic >/dev/null

  git init -q "$repo"
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" fetch -q origin topic:refs/remotes/origin/topic
  git -C "$repo" checkout -q --detach
  git -C "$repo" checkout -q -b topic origin/topic
  git -C "$repo" remote set-head origin --delete >/dev/null 2>&1 || true
  git -C "$repo" remote set-url origin "$TMP_ROOT/missing-single-topic-origin.git"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "default-branch repair guessed from a single fetched topic branch"
  fi
  assert_grep "cannot determine default branch" "$err" \
    "single fetched topic state did not fail with a clear error"
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/topic; then
    fail "single fetched topic repair seeded refs/heads/topic"
  fi
  pass "fm-no-mistakes-default-branch fails closed for a single fetched topic branch"
}

test_fails_closed_for_ancestry_only_default_guess() {
  local repo origin gate err
  repo="$TMP_ROOT/repo-linear-main-develop-topic"
  origin="$TMP_ROOT/origin-linear-main-develop-topic.git"
  gate="$TMP_ROOT/gate-linear-main-develop-topic.git"
  err="$TMP_ROOT/linear-main-develop-topic.err"
  make_repo_with_origin "$repo" "$origin" main
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  git -C "$repo" checkout -q -b develop
  printf 'develop\n' >> "$repo/README.md"
  git -C "$repo" commit -qam develop
  git -C "$repo" push -u origin develop >/dev/null
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/develop
  git -C "$repo" checkout -q -b topic
  printf 'topic\n' >> "$repo/README.md"
  git -C "$repo" commit -qam topic
  git -C "$repo" push -u origin topic >/dev/null
  git -C "$repo" checkout -q develop
  git -C "$repo" remote set-head origin --delete >/dev/null 2>&1 || true
  git -C "$repo" remote set-url origin "$TMP_ROOT/missing-linear-origin.git"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "default-branch repair guessed through ancestry-only evidence"
  fi
  assert_grep "cannot determine default branch" "$err" \
    "ancestry-only origin/HEAD-missing state did not fail with a clear error"
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/main; then
    fail "ancestry-only repair seeded refs/heads/main"
  fi
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/develop; then
    fail "ancestry-only repair seeded refs/heads/develop"
  fi
  pass "fm-no-mistakes-default-branch fails closed for ancestry-only default guesses"
}

test_fails_closed_when_origin_head_is_ambiguous() {
  local repo origin gate err
  repo="$TMP_ROOT/repo-ambiguous-default"
  origin="$TMP_ROOT/origin-ambiguous-default.git"
  gate="$TMP_ROOT/gate-ambiguous-default.git"
  err="$TMP_ROOT/ambiguous-default.err"
  make_repo_with_origin "$repo" "$origin" develop
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  git -C "$repo" checkout -q --orphan main
  printf 'main\n' > "$repo/MAIN.md"
  git -C "$repo" add MAIN.md
  git -C "$repo" commit -qm main
  git -C "$repo" push -u origin main >/dev/null
  git -C "$repo" checkout -q develop
  git -C "$repo" remote set-head origin --delete >/dev/null 2>&1 || true
  git -C "$repo" remote set-url origin "$TMP_ROOT/missing-ambiguous-origin.git"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "default-branch repair guessed through an ambiguous origin/HEAD-missing state"
  fi
  assert_grep "cannot determine default branch" "$err" \
    "ambiguous origin/HEAD-missing state did not fail with a clear error"
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/main; then
    fail "ambiguous repair seeded refs/heads/main"
  fi
  if git --git-dir="$gate" show-ref --verify --quiet refs/heads/develop; then
    fail "ambiguous repair seeded refs/heads/develop"
  fi
  pass "fm-no-mistakes-default-branch fails closed when origin/HEAD is ambiguous"
}

test_resolves_relative_gate_paths_from_repo_root() {
  local fixture repo origin gate out expected
  fixture="$TMP_ROOT/relative-gate-fixture"
  repo="$fixture/repo"
  origin="$fixture/origin.git"
  gate="$fixture/gate.git"
  mkdir -p "$fixture"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes ../gate.git

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair failed for relative gate path"
  expected=$(git -C "$repo" rev-parse origin/main)
  [ "$(git --git-dir="$gate" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not seed refs/heads/main through the relative gate path"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the relative-path self-heal"
  pass "fm-no-mistakes-default-branch resolves relative gate paths from the repo root"
}

test_resolves_relative_gate_paths_from_subdirectories() {
  local fixture repo origin gate out expected
  fixture="$TMP_ROOT/relative-gate-subdir-fixture"
  repo="$fixture/repo"
  origin="$fixture/origin.git"
  gate="$fixture/gate.git"
  mkdir -p "$fixture"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes ../gate.git
  mkdir -p "$repo/sub/dir"

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo/sub/dir") || fail "default-branch repair failed from a subdirectory"
  expected=$(git -C "$repo" rev-parse origin/main)
  [ "$(git --git-dir="$gate" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not seed refs/heads/main from a subdirectory invocation"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the subdirectory relative-path self-heal"
  pass "fm-no-mistakes-default-branch resolves relative gate paths from subdirectories"
}

test_resolves_relative_gate_paths_from_linked_worktrees() {
  local fixture repo origin gate_root gate_worktree worktrees worktree out expected
  fixture="$TMP_ROOT/relative-gate-worktree-fixture"
  repo="$fixture/repo"
  origin="$fixture/origin.git"
  gate_root="$fixture/gate.git"
  gate_worktree="$fixture/worktrees/gate.git"
  worktrees="$fixture/worktrees"
  worktree="$worktrees/task"
  mkdir -p "$worktrees"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate_root"
  git init --bare -q "$gate_worktree"
  git -C "$repo" remote add no-mistakes ../gate.git
  git -C "$repo" worktree add -q "$worktree" -b topic

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$worktree") || fail "default-branch repair failed from a linked worktree"
  expected=$(git -C "$worktree" rev-parse origin/main)
  [ "$(git --git-dir="$gate_worktree" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not seed the linked worktree's relative gate path"
  if git --git-dir="$gate_root" show-ref --verify --quiet refs/heads/main; then
    fail "repair incorrectly seeded the primary checkout's sibling gate path"
  fi
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the linked-worktree relative-path self-heal"
  pass "fm-no-mistakes-default-branch resolves relative gate paths from linked worktrees"
}

test_refreshes_stale_remote_default_before_repair() {
  local repo peer origin gate out expected stale
  repo="$TMP_ROOT/repo-stale-origin-main"
  peer="$TMP_ROOT/repo-stale-origin-main-peer"
  origin="$TMP_ROOT/origin-stale-origin-main.git"
  gate="$TMP_ROOT/gate-stale-origin-main.git"
  make_repo_with_origin "$repo" "$origin"
  git clone -q "$origin" "$peer"
  git -C "$peer" config user.name 'Firstmate Tests'
  git -C "$peer" config user.email 'tests@example.invalid'
  printf 'peer\n' >> "$peer/README.md"
  git -C "$peer" commit -qam peer
  git -C "$peer" push origin main >/dev/null
  git -C "$repo" remote set-head origin --delete >/dev/null 2>&1 || true
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"

  stale=$(git -C "$repo" rev-parse origin/main)
  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair failed for stale origin/main"
  expected=$(git --git-dir="$origin" rev-parse refs/heads/main)
  [ "$stale" != "$expected" ] || fail "test fixture did not leave origin/main stale before repair"
  [ "$(git -C "$repo" rev-parse origin/main)" = "$expected" ] \
    || fail "repair did not refresh origin/main before seeding the gate"
  [ "$(git --git-dir="$gate" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not seed refs/heads/main from the refreshed origin/main"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the stale-origin self-heal"
  pass "fm-no-mistakes-default-branch refreshes origin/main before repair"
}

test_repairs_divergent_gate_refs() {
  local repo origin gate out expected stale
  repo="$TMP_ROOT/repo-divergent-gate"
  origin="$TMP_ROOT/origin-divergent-gate.git"
  gate="$TMP_ROOT/gate-divergent-gate.git"
  make_repo_with_origin "$repo" "$origin"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  expected=$(git -C "$repo" rev-parse origin/main)
  git --git-dir="$gate" fetch --quiet "$repo" "refs/remotes/origin/main:refs/heads/main"
  git --git-dir="$gate" update-ref refs/remotes/origin/main "$expected"
  git -C "$repo" checkout -q --orphan replacement
  printf 'replacement\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm replacement
  git -C "$repo" branch -M main
  git -C "$repo" push --force origin main >/dev/null
  stale="$expected"
  expected=$(git --git-dir="$origin" rev-parse refs/heads/main)

  out=$("$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo") || fail "default-branch repair failed for divergent gate refs"
  [ "$stale" != "$expected" ] || fail "test fixture did not create a divergent replacement default"
  [ "$(git -C "$repo" rev-parse origin/main)" = "$expected" ] \
    || fail "repair did not force-refresh source origin/main"
  [ "$(git --git-dir="$gate" rev-parse refs/heads/main)" = "$expected" ] \
    || fail "repair did not force-replace divergent gate refs/heads/main"
  [ "$(git --git-dir="$gate" rev-parse refs/remotes/origin/main)" = "$expected" ] \
    || fail "repair did not update divergent gate refs/remotes/origin/main"
  assert_contains "$out" "healed: seeded no-mistakes gate mirror main, origin/main, and HEAD" \
    "repair did not report the divergent self-heal"
  pass "fm-no-mistakes-default-branch repairs divergent gate refs"
}

test_rejects_non_bare_gate_repo() {
  local repo origin gate err
  repo="$TMP_ROOT/repo-non-bare-gate"
  origin="$TMP_ROOT/origin-non-bare-gate.git"
  gate="$TMP_ROOT/non-bare-gate"
  err="$TMP_ROOT/non-bare-gate.err"
  make_repo_with_origin "$repo" "$origin"
  git init -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate/.git"

  if "$ROOT/bin/fm-no-mistakes-default-branch.sh" "$repo" >/dev/null 2>"$err"; then
    fail "repair accepted a non-bare no-mistakes gate repo"
  fi
  assert_grep "non-bare" "$err" \
    "non-bare no-mistakes gate repo did not fail with a clear error"
  pass "fm-no-mistakes-default-branch rejects non-bare gate repos"
}

test_repairs_missing_gate_refs
test_noop_when_gate_is_current
test_repairs_head_when_refs_are_already_seeded
test_fails_without_no_mistakes_remote
test_uses_non_main_default_branch_without_origin_head
test_prefers_single_remote_branch_over_local_main_fallback
test_fails_closed_for_lone_local_tracking_branch_when_origin_head_is_missing
test_fails_closed_for_single_fetched_topic_when_origin_head_is_missing
test_fails_closed_for_ancestry_only_default_guess
test_fails_closed_when_origin_head_is_ambiguous
test_resolves_relative_gate_paths_from_repo_root
test_resolves_relative_gate_paths_from_subdirectories
test_resolves_relative_gate_paths_from_linked_worktrees
test_refreshes_stale_remote_default_before_repair
test_repairs_divergent_gate_refs
test_rejects_non_bare_gate_repo
