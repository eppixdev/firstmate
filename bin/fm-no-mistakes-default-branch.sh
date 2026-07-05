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

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ $# -le 1 ] || { usage; exit 1; }
REPO=${1:-.}

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $REPO is not a git work tree" >&2; exit 1; }

DEFAULT=$(fm_default_branch "$REPO") \
  || { echo "error: cannot determine default branch for $REPO; expected origin/HEAD, main, or master" >&2; exit 1; }

SOURCE_REF=
for candidate in "refs/remotes/origin/$DEFAULT" "refs/heads/$DEFAULT"; do
  if git -C "$REPO" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
    SOURCE_REF=$candidate
    break
  fi
done
[ -n "$SOURCE_REF" ] \
  || { echo "error: source repo $REPO is missing $DEFAULT in both origin/$DEFAULT and local $DEFAULT" >&2; exit 1; }

GATE_URL=$(git -C "$REPO" config --get remote.no-mistakes.url 2>/dev/null || true)
[ -n "$GATE_URL" ] || { echo "error: repo $REPO is not initialized for no-mistakes (missing remote.no-mistakes.url)" >&2; exit 1; }

case "$GATE_URL" in
  file://*) GATE_DIR=${GATE_URL#file://} ;;
  *) GATE_DIR=$GATE_URL ;;
esac

git --git-dir="$GATE_DIR" rev-parse --is-bare-repository >/dev/null 2>&1 \
  || { echo "error: no-mistakes gate repo is missing or invalid: $GATE_DIR" >&2; exit 1; }

TARGET_SHA=$(git -C "$REPO" rev-parse "$SOURCE_REF^{commit}")
HEAD_REF="refs/heads/$DEFAULT"
REMOTE_REF="refs/remotes/origin/$DEFAULT"
HEAD_SHA=$(git --git-dir="$GATE_DIR" rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null || true)
REMOTE_SHA=$(git --git-dir="$GATE_DIR" rev-parse --verify --quiet "$REMOTE_REF^{commit}" 2>/dev/null || true)

if [ "$HEAD_SHA" = "$TARGET_SHA" ] && [ "$REMOTE_SHA" = "$TARGET_SHA" ]; then
  printf 'ok: no-mistakes gate mirror has %s at %s from %s\n' "$DEFAULT" "$TARGET_SHA" "$SOURCE_REF"
  exit 0
fi

git --git-dir="$GATE_DIR" fetch --quiet "$REPO" "$SOURCE_REF:$HEAD_REF"
git --git-dir="$GATE_DIR" update-ref "$REMOTE_REF" "$TARGET_SHA"
printf 'healed: seeded no-mistakes gate mirror %s and origin/%s at %s from %s\n' \
  "$DEFAULT" "$DEFAULT" "$TARGET_SHA" "$SOURCE_REF"
