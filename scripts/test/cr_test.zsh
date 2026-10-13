#!/usr/bin/env zsh

# Functional tests for the cr zsh function.
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
#     repo root, derive the session name from `origin` (or `(local)` when
#     the repo has none), and run claude with no throwaway and no
#     cleanup. The shell is intentionally left at the repo root afterward
#     (cr is a function, so the bare `cd` persists -- accepted behavior).
#   - With --cr-strict as its first argument: refuse outside a repo or in
#     a repo without `origin`; otherwise behave as plain cr.
#
# These tests use the REAL git binary and a stubbed `claude` function. The
# function under test is zsh-only (it relies on ${(q)...} quoting and zsh
# parameter expansion), so this test is a .zsh script, unlike the bash
# *_test.sh scripts that cover the POSIX shell layer.
#
# Each case runs cr inside a `( ... )` subshell so the case's `cd`, its
# `claude` stub, any trap it sets, and the `cd` cr itself leaves behind
# stay out of the test shell. cr's function-local EXIT trap fires when cr
# returns, inside the subshell, so the parent observes the post-cleanup
# filesystem state.

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

# --- Test 6: name words plus claude flags -> --allowedTools Grep Glob sits
#     ahead of the forwarded flags, and the name words form the session
#     name. Each argument claude receives is written on its own line. -----
t6="$(mktemp -d)"
(
    cd "$t6"
    git init >/dev/null 2>&1
    git remote add origin https://example.com/argrepo.git 2>/dev/null
    claude () { print -rl -- "$@" > "$t6/args"; return 0 }
    cr my name --model opus "prompt" >/dev/null 2>&1
)
t6args=("${(@f)$(cat "$t6/args" 2>/dev/null)}")
if [[ "${t6args[2]-}" == "my name argrepo" ]]; then
    pass "args: session name is 'my name argrepo'"
else
    die  "args: session name was '${t6args[2]-}'"
fi
if [[ "${(j: :)t6args[-6,-1]}" == "--allowedTools Grep Glob --model opus prompt" ]]; then
    pass "args: --allowedTools Grep Glob passed ahead of --model opus prompt"
else
    die  "args: claude got '${(j: :)t6args}'"
fi
rm -rf "$t6"

# --- Test 7: no arguments -> --allowedTools Grep Glob still passed. ------
t7="$(mktemp -d)"
(
    cd "$t7"
    git init >/dev/null 2>&1
    claude () { print -rl -- "$@" > "$t7/args"; return 0 }
    cr >/dev/null 2>&1
)
t7args=("${(@f)$(cat "$t7/args" 2>/dev/null)}")
if [[ "${(j: :)t7args[-3,-1]}" == "--allowedTools Grep Glob" ]]; then
    pass "no args: --allowedTools Grep Glob still passed"
else
    die  "no args: claude got '${(j: :)t7args}'"
fi
rm -rf "$t7"

# --- Test 8: --cr-strict outside any repo -> non-zero, error on stderr, no
#     .git created, claude never runs. -----------------------------------
t8="$(mktemp -d)"
(
    cd "$t8"
    claude () { print "ran" > "$t8/claude-ran"; return 0 }
    cr --cr-strict x 2> "$t8/stderr" >/dev/null
    print -- "$?" > "$t8/status"
)
if [[ "$(cat "$t8/status" 2>/dev/null)" != "0" && -s "$t8/stderr" \
      && ! -e "$t8/.git" && ! -e "$t8/claude-ran" ]]; then
    pass "strict non-repo: refused with an error, no .git, no claude"
else
    die  "strict non-repo: status '$(cat "$t8/status" 2>/dev/null)', stderr '$(cat "$t8/stderr" 2>/dev/null)'"
fi
rm -rf "$t8"

# --- Test 9: --cr-strict in a repo without origin -> non-zero, claude
#     never runs. ---------------------------------------------------------
t9="$(mktemp -d)"
(
    cd "$t9"
    git init >/dev/null 2>&1
    claude () { print "ran" > "$t9/claude-ran"; return 0 }
    cr --cr-strict 2> "$t9/stderr" >/dev/null
    print -- "$?" > "$t9/status"
)
if [[ "$(cat "$t9/status" 2>/dev/null)" != "0" && -s "$t9/stderr" \
      && ! -e "$t9/claude-ran" ]]; then
    pass "strict no-origin: refused with an error, no claude"
else
    die  "strict no-origin: status '$(cat "$t9/status" 2>/dev/null)', stderr '$(cat "$t9/stderr" 2>/dev/null)'"
fi
rm -rf "$t9"

# --- Test 10: --cr-strict in a repo with origin -> claude gets exactly the
#     arguments plain cr passes, without --cr-strict. Both runs share one
#     fixed name so the timestamp fallback cannot differ between them. ---
t10="$(mktemp -d)"
(
    cd "$t10"
    git init >/dev/null 2>&1
    git remote add origin https://example.com/strictrepo.git 2>/dev/null
    claude () { print -rl -- "$@" > "$t10/args-strict"; return 0 }
    cr --cr-strict my name --model opus >/dev/null 2>&1
    claude () { print -rl -- "$@" > "$t10/args-plain"; return 0 }
    cr my name --model opus >/dev/null 2>&1
)
if [[ -s "$t10/args-strict" ]] \
      && cmp -s "$t10/args-strict" "$t10/args-plain" \
      && ! grep -qx -- '--cr-strict' "$t10/args-strict"; then
    pass "strict with origin: claude got the plain-cr arguments, no --cr-strict"
else
    die  "strict with origin: claude got '$(cat "$t10/args-strict" 2>/dev/null)'"
fi
rm -rf "$t10"

# --- Test 11: --cr-strict in a later position -> forwarded to claude
#     unchanged, and no strict check (a repo without origin still runs). --
t11="$(mktemp -d)"
(
    cd "$t11"
    git init >/dev/null 2>&1
    claude () { print -rl -- "$@" > "$t11/args"; return 0 }
    cr my name --model opus --cr-strict >/dev/null 2>&1
)
t11args=("${(@f)$(cat "$t11/args" 2>/dev/null)}")
if [[ "${(j: :)t11args[-3,-1]}" == "--model opus --cr-strict" ]]; then
    pass "strict later position: --cr-strict forwarded to claude"
else
    die  "strict later position: claude got '${(j: :)t11args}'"
fi
rm -rf "$t11"

# --- Test 12: outside any repo -> the caller's INT and TERM traps are
#     restored when cr returns, so the throwaway rm never fires from the
#     calling shell afterwards. The `emulate -L zsh` above turns LOCAL_TRAPS
#     on, so the subshell turns it back off, its zsh default. -------------
t12="$(mktemp -d)"
(
    cd "$t12"
    unsetopt LOCAL_TRAPS
    trap 'print caller-int' INT
    claude () { return 0 }
    cr >/dev/null 2>&1
    trap > "$t12/traps"
)
if grep -q 'caller-int' "$t12/traps" 2>/dev/null \
      && ! grep -q 'rm -rf' "$t12/traps" 2>/dev/null; then
    pass "non-repo: caller's INT and TERM traps restored after cr returns"
else
    die  "non-repo: traps after cr were '$(cat "$t12/traps" 2>/dev/null)'"
fi
rm -rf "$t12"

print
print -- "---"
print -- "pass=$pass fail=$fail"
if (( fail == 0 )); then
    print -- "All cr tests passed."
    exit 0
fi
print -- "Some cr tests FAILED."
exit 1
