#!/usr/bin/env bash
#
# no-back-merging-guard.sh
#
# Reject PR head branches that contain a back-merge from the base branch.
# A "back-merge" is a merge commit on the head branch whose second parent
# (the "incoming" side of the merge) is reachable from the base branch
# tip. That is the signature of `git merge origin/<base>` performed on
# the feature branch. Feature branches must rebase, not merge, to bring
# in upstream changes.
#
# Walk only commits unique to the head branch (`<base>..<head>`). Merge
# commits whose ancestors happen to be on `<base>` from a previous
# round-trip are NOT in that range, so they cannot trigger a false
# positive. Internal merges from a sub-branch (where the second parent
# is NOT reachable from `<base>`) are accepted.
#
# Inputs:
#   $1 -- base ref (e.g. "origin/main")
#   $2 -- head ref or SHA (defaults to HEAD)
#
# Exit codes:
#   0 -- clean: no back-merges detected
#   1 -- back-merge detected
#   2 -- usage / git error
#
# Used by .github/workflows/no-back-merging-guard.yml. Self-tested by
# .github/scripts/test-no-back-merging-guard.sh.

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <base-ref> [head-ref]" >&2
  exit 2
fi

BASE="$1"
HEAD="${2:-HEAD}"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "::error::base ref '$BASE' not found. Fetch it before running this guard." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "$HEAD" >/dev/null; then
  echo "::error::head ref '$HEAD' not found." >&2
  exit 2
fi

# Walk only merge commits unique to the head branch.
found=0
while read -r merge_sha; do
  [ -z "$merge_sha" ] && continue

  # Parents of the merge: parent1 is the trunk side of the feature
  # branch at the time of the merge; parent2 is the "incoming" side.
  # A back-merge from <base> shows up as parent2 being reachable from
  # the current <base> tip.
  parents=$(git log -1 --pretty=%P "$merge_sha")
  # shellcheck disable=SC2206  # word-splitting is intentional
  parent_arr=($parents)

  if [ "${#parent_arr[@]}" -lt 2 ]; then
    # Defensive: --merges should only return commits with >=2 parents.
    continue
  fi

  second_parent="${parent_arr[1]}"
  if git merge-base --is-ancestor "$second_parent" "$BASE" 2>/dev/null; then
    echo "::error::Back-merge detected in $merge_sha -- its incoming parent $second_parent is reachable from $BASE."
    echo "Rebase your branch onto $BASE instead: git fetch origin && git rebase $BASE"
    found=1
  fi
done < <(git log --merges "$BASE..$HEAD" --pretty=%H)

if [ "$found" -eq 1 ]; then
  exit 1
fi

echo "OK: no back-merges from $BASE on $HEAD."
exit 0
