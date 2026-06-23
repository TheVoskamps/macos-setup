#!/usr/bin/env bash
# scripts/self_update.sh — safely pull the latest `main` into this repo.
# See print_help() below for the user-facing description.

set -euo pipefail

# --- User-facing help ---
print_help() {
  cat <<'EOF'
scripts/self_update.sh — safely pull the latest `main` into this repo.

Usage:
  scripts/self_update.sh            # do it
  scripts/self_update.sh --dry-run  # print what would happen, do nothing
  scripts/self_update.sh -h|--help  # show this help

Behavior:
  - If on a branch other than `main`, switch to `main`.
  - If the working tree is dirty (staged, unstaged, or untracked),
    `git stash push --include-untracked` -> pull -> `git stash pop`.
  - If clean and on `main`, just pull.
  - Print before/after SHA for `main` on success.

Refuses (does nothing, exits non-zero) if:
  - Not inside this repo (the repo containing this script).
  - Running inside a linked worktree (e.g. under `.claude/worktrees/`).
    Run from the main checkout instead; the worktree's branch is
    independent of `main`.
  - Detached HEAD.
  - A rebase / merge / cherry-pick / revert / bisect is in progress.
  - The pull fails (non-fast-forward, network error, etc.).
  - `git stash pop` conflicts — the user's changes remain in stash@{0}
    and must be resolved manually.

Out of scope: updating Homebrew/asdf/installed software (use
`make update`), rebasing the original branch onto the new `main`,
auto-resolving conflicts.
EOF
}

# --- Argument parsing ---
DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "")        ;;
  -h|--help)
    print_help
    exit 0
    ;;
  *)
    echo "Usage: $(basename "$0") [--dry-run]" >&2
    exit 64
    ;;
esac

# --- Resolve the repo this script lives in ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Helpers ---
say()  { echo "[self-update] $*"; }
warn() { echo "[self-update] $*" >&2; }
fail() {
  warn "$*"
  exit 1
}

run() {
  # Print and execute, unless dry-run. With `set -e`, a non-zero
  # exit from "$@" propagates and the script aborts (the EXIT trap
  # below prints stash recovery info if we'd already stashed).
  echo "+ $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

# --- EXIT trap: tell the user where their stashed changes are if we abort ---
STASHED=0
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && $STASHED -eq 1 ]]; then
    warn "your changes are still saved in stash@{0} (message: 'self-update auto-stash')."
    warn "to restore them: 'git stash pop'. To discard: 'git stash drop'."
  fi
}
trap on_exit EXIT

# --- Refusal: must be inside a git repo ---
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "refusing: not inside a git repository (run this from inside the macos-setup repo)."
fi

CURRENT_REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Refusal: the script must live inside the current repo ---
# This makes the script path-agnostic: it works from the main checkout
# of the same repo, but refuses if the script has been copied into an
# unrelated directory or another repo. (Linked worktrees are caught by
# the dedicated check below.)
case "$SCRIPT_REPO_ROOT/" in
  "$CURRENT_REPO_ROOT/"*) ;;
  *)
    fail "refusing: this script ($SCRIPT_DIR) is not inside the current repo ($CURRENT_REPO_ROOT)."
    ;;
esac

# --- Refusal: linked worktree (e.g. under `.claude/worktrees/`) ---
# In a linked worktree, `git rev-parse --git-dir` returns a per-worktree
# path (e.g. `.git/worktrees/<name>`) while `--git-common-dir` returns
# the main `.git` directory. They differ if and only if we're in a
# linked worktree. Equivalently, in a linked worktree the worktree's
# `.git` is a file (not a directory). We refuse here because:
#   - `git checkout main` fails ("already checked out elsewhere"),
#     leaving the script on the worktree's branch;
#   - a subsequent `git pull --ff-only` would silently fast-forward
#     the *worktree's* branch instead of `main`;
#   - `git stash pop` would then run on the wrong branch.
# Refusing avoids that whole class of corruption.
GIT_DIR_RAW="$(git rev-parse --git-dir)"
GIT_COMMON_DIR_RAW="$(git rev-parse --git-common-dir)"
GIT_DIR_ABS="$(cd "$GIT_DIR_RAW" && pwd)"
GIT_COMMON_DIR_ABS="$(cd "$GIT_COMMON_DIR_RAW" && pwd)"
if [[ "$GIT_DIR_ABS" != "$GIT_COMMON_DIR_ABS" ]]; then
  warn "refusing: this is a linked worktree (git-dir != git-common-dir)."
  warn "  git-dir:        $GIT_DIR_ABS"
  warn "  git-common-dir: $GIT_COMMON_DIR_ABS"
  warn "run 'make self-update' from the main checkout instead. The worktree's"
  warn "branch is independent of main; updating it via this script would either"
  warn "fail (main is already checked out elsewhere) or silently fast-forward"
  warn "the wrong branch."
  warn "tip: 'git worktree list' shows where main is checked out."
  exit 1
fi

GIT_DIR="$GIT_DIR_ABS"

# --- Refusal: detached HEAD ---
if ! CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD)"; then
  fail "refusing: detached HEAD. Check out a branch first (e.g. 'git checkout main')."
fi

# --- Refusal: in-progress rebase / merge / cherry-pick / revert / bisect ---
for marker in \
  "rebase-merge" \
  "rebase-apply" \
  "MERGE_HEAD" \
  "CHERRY_PICK_HEAD" \
  "REVERT_HEAD" \
  "BISECT_LOG"; do
  if [[ -e "$GIT_DIR/$marker" ]]; then
    fail "refusing: in-progress operation detected ($marker). Finish or abort it first."
  fi
done

# --- Detect dirty tree ---
DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  DIRTY=1
fi

# --- Plan ---
echo
say "repo:           $CURRENT_REPO_ROOT"
say "current branch: $CURRENT_BRANCH"
say "dirty tree:     $([[ $DIRTY -eq 1 ]] && echo yes || echo no)"
if [[ $DRY_RUN -eq 1 ]]; then
  say "mode:           dry-run (no changes will be made)"
fi
echo

# --- Capture before-SHA ---
# `git rev-parse main` works whether or not `main` is the current
# branch; if `main` doesn't exist locally that's a setup error worth
# refusing on.
if ! BEFORE_SHA="$(git rev-parse --verify main 2>/dev/null)"; then
  fail "refusing: no local 'main' branch. Create one first (e.g. 'git checkout -b main origin/main')."
fi
say "main before:    $BEFORE_SHA"

# --- Stash if dirty ---
STASH_MESSAGE="self-update auto-stash"
if [[ $DIRTY -eq 1 ]]; then
  run git stash push --include-untracked --message "$STASH_MESSAGE"
  if [[ $DRY_RUN -eq 0 ]]; then
    # Verify the stash actually landed at stash@{0} by inspecting its
    # message. If it didn't (e.g. an empty stash collapsed to a no-op,
    # or a hook intervened), refuse rather than risk popping an
    # unrelated entry the user already had on the stack.
    TOP_STASH_MSG="$(git stash list -n 1 --format='%gs' 2>/dev/null || echo '')"
    case "$TOP_STASH_MSG" in
      *"$STASH_MESSAGE"*)
        STASHED=1
        ;;
      *)
        fail "refusing: 'git stash push' did not produce a 'self-update auto-stash' entry at stash@{0} (saw: '$TOP_STASH_MSG'). Aborting before any other mutation."
        ;;
    esac
  fi
fi

# --- Switch to main if needed ---
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  run git checkout main
fi

# --- Pull ---
if [[ $DRY_RUN -eq 0 ]]; then
  if ! git pull --ff-only; then
    fail "refusing: 'git pull --ff-only' failed (non-fast-forward, network error, or similar)."
  fi
else
  echo "+ git pull --ff-only"
fi

# --- Pop stash if we stashed ---
if [[ $STASHED -eq 1 ]]; then
  if ! git stash pop; then
    warn "refusing: 'git stash pop' had conflicts."
    warn "your changes are partially applied to the working tree (with conflict"
    warn "markers); the stash entry is preserved at stash@{0}. Resolve the"
    warn "conflicts in the working tree, stage/commit them, then run"
    warn "'git stash drop' to remove the saved copy."
    # Don't let the EXIT trap re-print generic stash-recovery advice
    # on top of this more specific guidance.
    STASHED=0
    exit 1
  fi
  # Pop succeeded: the stash entry is gone, so a later unrelated failure
  # must not cause the EXIT trap to tell the user it's still in stash@{0}.
  STASHED=0
elif [[ $DRY_RUN -eq 1 && $DIRTY -eq 1 ]]; then
  # Show the would-be pop in dry-run so the printed plan matches what
  # a real run executes.
  echo "+ git stash pop"
fi

# --- Output: SHA / status ---
echo
if [[ $DRY_RUN -eq 1 ]]; then
  say "main after:     (would be queried after pull)"
  say "dry-run complete; no changes were made."
else
  AFTER_SHA="$(git rev-parse --verify main)"
  say "main after:     $AFTER_SHA"
  if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    say "already up to date."
  else
    say "updated $BEFORE_SHA -> $AFTER_SHA."
  fi
fi
