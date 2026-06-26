#!/usr/bin/env zsh

# Functional tests for the cr zsh function (issue #15).
#
# cr lives in profiles/claude-code-aliases/aliases.zsh. It wraps
# the `claude` CLI so it works both inside and outside a git repo:
#
#   - Outside any repo: `git init` a throwaway repo so Claude Code's
#     git-using guardrails hook has a repo to anchor on, run claude, then
#     remove ONLY the .git it created -- via a function-local trap so the
#     cleanup runs on every return path (normal exit, early return, or the
#     user interrupting claude with Ctrl-C, and on INT/TERM that kill the
#     shell).
#   - Inside an existing repo (at the root OR any subdirectory): detect
#     the repo with `git rev-parse --is-inside-work-tree`, `cd` to the
#     repo root, derive the session name from `origin`, and run claude
#     with no throwaway and no cleanup. The shell is intentionally left at
#     the repo root afterward (cr is a function, so the bare `cd`
#     persists -- accepted behavior).
#
# These tests use the REAL git binary and a stubbed `claude` function. The
# function under test is zsh-only (it relies on ${(q)...} quoting and zsh
# parameter expansion), so this test is a .zsh script, unlike the bash
# *_test.sh scripts that cover the POSIX shell layer.
#
# Each case runs cr inside a `( ... )` subshell so its function-
# local EXIT trap fires at the subshell boundary, letting the parent
# observe the post-cleanup filesystem state.

emulate -L zsh
set -u

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
PROFILE="$REPO_ROOT/profiles/claude-code-aliases/aliases.zsh"

if [[ ! -r "$PROFILE" ]]; then
    print -- "FAIL: cannot read $PROFILE" >&2
    exit 1
fi

pass=0
fail=0
pass () { print -- "PASS: $1"; ((pass++)) }
die  () { print -- "FAIL: $1"; ((fail++)) }

# Load the real cr definition under test.
source "$PROFILE"

# --- Test 1: outside any repo -> throwaway .git created during the run,
#     removed on normal exit. ---------------------------------------------
t1="$(mktemp -d)"
(
    cd "$t1"
    claude () { [[ -d .git ]] && print "claude-saw-git" >> "$t1/marker"; return 0 }
    cr x >/dev/null 2>&1
)
if [[ -f "$t1/marker" && ! -d "$t1/.git" ]]; then
    pass "non-repo: throwaway .git created for claude then cleaned on normal exit"
else
    die  "non-repo: expected .git during run and removed after"
fi
rm -rf "$t1"

# --- Test 2: outside any repo, claude aborts (non-zero / Ctrl-C) -> .git
#     still cleaned via the trap. -----------------------------------------
t2="$(mktemp -d)"
(
    cd "$t2"
    claude () { return 130 }   # simulate Ctrl-C / abort
    cr >/dev/null 2>&1
)
if [[ ! -d "$t2/.git" ]]; then
    pass "non-repo: throwaway .git cleaned even when claude aborts"
else
    die  "non-repo: .git survived an aborted claude run"
fi
rm -rf "$t2"

# --- Test 3: existing repo, invoked at repo ROOT -> its real .git is
#     preserved (no rm), session name derived from origin. ----------------
t3="$(mktemp -d)"
(
    cd "$t3"
    git init >/dev/null 2>&1
    git remote add origin https://example.com/myrepo.git 2>/dev/null
    print "sentinel" > .git/SENTINEL_DO_NOT_DELETE
    claude () { print -- "$2" > "$t3/name-arg"; return 0 }  # $2 == --name value
    cr >/dev/null 2>&1
)
if [[ -d "$t3/.git" && -f "$t3/.git/SENTINEL_DO_NOT_DELETE" ]]; then
    pass "existing repo at root: real .git preserved"
else
    die  "existing repo at root: real .git was damaged"
fi
if [[ "$(cat "$t3/name-arg" 2>/dev/null)" == *"myrepo"* ]]; then
    pass "existing repo at root: session name derived from origin (myrepo)"
else
    die  "existing repo at root: name not derived from origin"
fi
rm -rf "$t3"

# --- Test 4: existing repo, invoked from a SUBDIRECTORY -> detect repo,
#     cd to repo root, preserve real .git, derive name from origin, and
#     leave the shell at the repo root. -----------------------------------
t4="$(mktemp -d)"
(
    cd "$t4"
    git init >/dev/null 2>&1
    git remote add origin https://example.com/subrepo.git 2>/dev/null
    print "sentinel" > .git/SENTINEL
    mkdir -p deep/nested
    cd deep/nested
    claude () { print -- "$2" > "$t4/name-arg"; print -- "$PWD" > "$t4/cwd-after"; return 0 }
    cr >/dev/null 2>&1
)
if [[ -f "$t4/.git/SENTINEL" && ! -d "$t4/deep/nested/.git" ]]; then
    pass "subdir: existing .git preserved, no throwaway created in subdir"
else
    die  "subdir: .git handling wrong"
fi
if [[ "$(cat "$t4/name-arg" 2>/dev/null)" == *"subrepo"* ]]; then
    pass "subdir: session name derived from origin (subrepo), not (local)"
else
    die  "subdir: name not derived from origin"
fi
# Resolve symlinks on both sides (macOS /tmp is a symlink to /private/tmp).
if [[ "${$(cat "$t4/cwd-after" 2>/dev/null):A}" == "${t4:A}" ]]; then
    pass "subdir: cd'd to repo root before launching claude"
else
    die  "subdir: did not cd to repo root"
fi
rm -rf "$t4"

# --- Test 5: spaces in path -> throwaway .git path with spaces is quoted
#     correctly by ${(q)...} so cleanup still works. ----------------------
t5parent="$(mktemp -d)"
t5="$t5parent/dir with spaces"
mkdir -p "$t5"
(
    cd "$t5"
    claude () { return 0 }
    cr >/dev/null 2>&1
)
if [[ ! -d "$t5/.git" ]]; then
    pass "spaces-in-path: throwaway .git cleaned despite spaces in path"
else
    die  "spaces-in-path: .git survived (quoting bug)"
fi
rm -rf "$t5parent"

print
print -- "---"
print -- "pass=$pass fail=$fail"
if (( fail == 0 )); then
    print -- "All cr tests passed."
    exit 0
fi
print -- "Some cr tests FAILED."
exit 1
