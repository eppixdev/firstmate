#!/usr/bin/env bash
# Ensure the no-mistakes gate mirror has the repo's default-branch refs.
#
# no-mistakes review worktrees are created from the local gate mirror registered
# at remote.no-mistakes.url. Some repos were initialized with a mirror that
# never received the default branch, which let downstream review logic compute
# scope from an empty tree instead of the real base. This helper makes that
# invariant explicit: resolve the authoritative default-branch commit from the
# source repo, then verify or repair the gate mirror's refs for it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

usage() {
  echo "usage: fm-no-mistakes-default-branch.sh [repo]" >&2
}

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi

run_git_probe() {
  local limit=$1
  shift
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$limit" "$@" ;;
    gtimeout) gtimeout "$limit" "$@" ;;
    perl)
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$limit" "$@"
      ;;
    *)
      return 127
      ;;
  esac
}

probe_origin_default_branch() {
  local repo=$1
  run_git_probe "${FM_DEFAULT_BRANCH_REMOTE_TIMEOUT:-5}" \
    git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null \
    | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]\+HEAD$#\1#p' \
    | sed -n '/./{p;q;}'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ $# -le 1 ] || { usage; exit 1; }
REPO=${1:-.}

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $REPO is not a git work tree" >&2; exit 1; }
WORKTREE_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)

DEFAULT=$(fm_default_branch "$REPO" 2>/dev/null || true)
if [ -z "$DEFAULT" ] && git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  DEFAULT=$(probe_origin_default_branch "$REPO" || true)
fi
[ -n "$DEFAULT" ] \
  || { echo "error: cannot determine default branch for $REPO; expected local origin/HEAD, bounded origin HEAD probe, or local-only unambiguous branch evidence" >&2; exit 1; }

SOURCE_REF=
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  git -C "$REPO" fetch --quiet origin "refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" >/dev/null 2>&1 \
    || { echo "error: unable to refresh origin/$DEFAULT in $REPO before repairing the no-mistakes gate mirror" >&2; exit 1; }
  SOURCE_REF="refs/remotes/origin/$DEFAULT"
elif git -C "$REPO" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}" >/dev/null; then
  SOURCE_REF="refs/heads/$DEFAULT"
fi
[ -n "$SOURCE_REF" ] \
  || { echo "error: source repo $REPO is missing $DEFAULT in both origin/$DEFAULT and local $DEFAULT" >&2; exit 1; }

GATE_URL=$(git -C "$REPO" config --get remote.no-mistakes.url 2>/dev/null || true)
[ -n "$GATE_URL" ] || { echo "error: repo $REPO is not initialized for no-mistakes (missing remote.no-mistakes.url)" >&2; exit 1; }

case "$GATE_URL" in
  file://*) GATE_DIR=${GATE_URL#file://} ;;
  /*) GATE_DIR=$GATE_URL ;;
  *)
    GATE_DIR=$(cd "$WORKTREE_ROOT" && cd "$GATE_URL" 2>/dev/null && pwd -P) \
      || { echo "error: no-mistakes gate repo is missing or invalid: $GATE_URL" >&2; exit 1; }
    ;;
esac

IS_BARE=$(git --git-dir="$GATE_DIR" rev-parse --is-bare-repository 2>/dev/null || true)
[ "$IS_BARE" = "true" ] \
  || { echo "error: no-mistakes gate repo is missing, invalid, or non-bare: $GATE_DIR" >&2; exit 1; }

TARGET_SHA=$(git -C "$REPO" rev-parse "$SOURCE_REF^{commit}")
HEAD_REF="refs/heads/$DEFAULT"
REMOTE_REF="refs/remotes/origin/$DEFAULT"
HEAD_SYMREF=$(git --git-dir="$GATE_DIR" symbolic-ref --quiet HEAD 2>/dev/null || true)
HEAD_SHA=$(git --git-dir="$GATE_DIR" rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null || true)
REMOTE_SHA=$(git --git-dir="$GATE_DIR" rev-parse --verify --quiet "$REMOTE_REF^{commit}" 2>/dev/null || true)

if [ "$HEAD_SHA" = "$TARGET_SHA" ] \
  && [ "$REMOTE_SHA" = "$TARGET_SHA" ] \
  && [ "$HEAD_SYMREF" = "$HEAD_REF" ]; then
  printf 'ok: no-mistakes gate mirror has %s at %s from %s\n' "$DEFAULT" "$TARGET_SHA" "$SOURCE_REF"
  exit 0
fi

git --git-dir="$GATE_DIR" fetch --quiet "$WORKTREE_ROOT" "$SOURCE_REF:$HEAD_REF"
git --git-dir="$GATE_DIR" update-ref "$REMOTE_REF" "$TARGET_SHA"
git --git-dir="$GATE_DIR" symbolic-ref HEAD "$HEAD_REF"
printf 'healed: seeded no-mistakes gate mirror %s, origin/%s, and HEAD at %s from %s\n' \
  "$DEFAULT" "$DEFAULT" "$TARGET_SHA" "$SOURCE_REF"
