#!/usr/bin/env bash
#
# test-no-back-merging-guard.sh
#
# Self-test for .github/scripts/no-back-merging-guard.sh. Builds throwaway git
# repos under a temp dir and verifies that the guard accepts clean
# branches and rejects branches that contain `git merge <base>`.
#
# Cases:
#   (a) Clean linear feature branch -- pass
#   (b) Feature branch with `git merge <base>` -- fail
#   (c) Feature branch with an internal merge from a sub-branch (no
#       main-ancestor parent) -- pass (no false positive)
#   (d) Feature branch that back-merged base earlier, base then
#       advances further -- still fail (the merge is still in
#       <base>..HEAD and parent2 is still reachable from <base>)
#
# Exit codes:
#   0 -- all cases pass
#   1 -- any case fails

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/no-back-merging-guard.sh"

if [ ! -x "$GUARD" ]; then
  echo "FAIL: guard script not executable at $GUARD" >&2
  exit 1
fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t no-back-merging-guard)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Common author identity so commits work without global git config.
git_init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test User"
  git -C "$dir" config commit.gpgsign false
}

commit_file() {
  local dir="$1" file="$2" msg="$3"
  echo "$msg" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$msg"
}

run_case() {
  local name="$1" expected_exit="$2" repo="$3" base="$4" head="$5"
  local out actual
  set +e
  out=$(cd "$repo" && "$GUARD" "$base" "$head" 2>&1)
  actual=$?
  set -e
  if [ "$actual" = "$expected_exit" ]; then
    pass=$((pass + 1))
    echo "PASS [$name] (exit $actual)"
  else
    fail=$((fail + 1))
    echo "FAIL [$name] expected exit $expected_exit, got $actual"
    echo "----- guard output -----"
    echo "$out"
    echo "------------------------"
  fi
}

# ---------------------------------------------------------------
# Case (a): Clean linear feature branch
# ---------------------------------------------------------------
REPO_A="$TMP/case-a"
git_init_repo "$REPO_A"
commit_file "$REPO_A" base.txt "base 1"
commit_file "$REPO_A" base.txt "base 2"
git -C "$REPO_A" checkout -q -b feature
commit_file "$REPO_A" feat.txt "feat 1"
commit_file "$REPO_A" feat.txt "feat 2"
run_case "a: clean linear feature" 0 "$REPO_A" main feature

# ---------------------------------------------------------------
# Case (b): Feature branch with `git merge main`
# ---------------------------------------------------------------
REPO_B="$TMP/case-b"
git_init_repo "$REPO_B"
commit_file "$REPO_B" base.txt "base 1"
git -C "$REPO_B" checkout -q -b feature
commit_file "$REPO_B" feat.txt "feat 1"
git -C "$REPO_B" checkout -q main
commit_file "$REPO_B" base.txt "base 2"
git -C "$REPO_B" checkout -q feature
# This is the forbidden operation: pull main into the feature branch
# via a merge commit instead of rebasing.
git -C "$REPO_B" merge -q --no-ff -m "Merge branch 'main' into feature" main
commit_file "$REPO_B" feat.txt "feat 2 after back-merge"
run_case "b: back-merge from main" 1 "$REPO_B" main feature

# ---------------------------------------------------------------
# Case (c): Internal merge from a sub-branch (no main-ancestor parent)
# ---------------------------------------------------------------
REPO_C="$TMP/case-c"
git_init_repo "$REPO_C"
commit_file "$REPO_C" base.txt "base 1"
git -C "$REPO_C" checkout -q -b feature
commit_file "$REPO_C" feat.txt "feat 1"
git -C "$REPO_C" checkout -q -b sub-feature
commit_file "$REPO_C" sub.txt "sub 1"
commit_file "$REPO_C" sub.txt "sub 2"
git -C "$REPO_C" checkout -q feature
# Merging a sub-branch INTO the feature branch is fine: the second
# parent (sub-feature tip) is NOT reachable from main.
git -C "$REPO_C" merge -q --no-ff -m "Merge sub-feature into feature" sub-feature
run_case "c: internal merge from sub-branch" 0 "$REPO_C" main feature

# ---------------------------------------------------------------
# Case (d): Back-merge then main advances further -- still fail
# ---------------------------------------------------------------
REPO_D="$TMP/case-d"
git_init_repo "$REPO_D"
commit_file "$REPO_D" base.txt "base 1"
git -C "$REPO_D" checkout -q -b feature
commit_file "$REPO_D" feat.txt "feat 1"
git -C "$REPO_D" checkout -q main
commit_file "$REPO_D" base.txt "base 2"
git -C "$REPO_D" checkout -q feature
git -C "$REPO_D" merge -q --no-ff -m "Merge branch 'main' into feature (early)" main
commit_file "$REPO_D" feat.txt "feat 2"
# Main advances further AFTER the back-merge. The back-merge commit
# stays in main..feature and its second parent stays reachable from
# main, so the guard must still reject.
git -C "$REPO_D" checkout -q main
commit_file "$REPO_D" base.txt "base 3"
run_case "d: back-merge then main advances" 1 "$REPO_D" main feature

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
