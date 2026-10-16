#!/usr/bin/env zsh

# Functional tests for update-claude-plugins, update-claude-config, and
# the update_claude_plugins compatibility name (issue #83).
#
# The helpers live in profiles/claude-code-aliases/aliases.zsh and run
# scripts from the ~/.claude checkout: update-claude-plugins runs
# ~/.claude/plugins.sh --update, update-claude-config runs
# ~/.claude/config.sh, each with the caller's arguments appended and the
# script's exit status returned.
#
# HOME is pointed at a temp dir holding stub .claude/plugins.sh and
# .claude/config.sh. Each stub writes its arguments, one per line, to
# $HOME/args and exits with $STUB_EXIT, so the real ~/.claude is never
# run.

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

source "$PROFILE"

TEST_HOME="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_HOME"' EXIT
HOME="$TEST_HOME"
mkdir -p "$HOME/.claude"

write_stub () {
    print -r -- '#!/bin/sh
printf "%s\n" "$@" > "$HOME/args"
exit "${STUB_EXIT:-0}"' > "$HOME/.claude/$1"
    chmod 0755 "$HOME/.claude/$1"
}

# Run "$@" with STUB_EXIT=$1 (shifted off), recording its stderr in $err,
# its exit status in $rc, and the stub's arguments in $args.
run () {
    local stub_exit=$1
    shift
    command rm -f "$HOME/args"
    err="$(STUB_EXIT=$stub_exit "$@" 2>&1 >/dev/null)"
    rc=$?
    args="$(cat "$HOME/args" 2>/dev/null)"
}

write_stub plugins.sh
write_stub config.sh

# --- Test 1: update-claude-plugins runs plugins.sh --update with the
#     caller's arguments appended and returns its status. ----------------
run 3 update-claude-plugins --dry-run 'two words'
if [[ $rc -eq 3 && "$args" == $'--update\n--dry-run\ntwo words' && -z "$err" ]]; then
    pass "update-claude-plugins runs plugins.sh --update <args> and returns its status"
else
    die "update-claude-plugins: rc=$rc args=${(q)args} err=${(q)err}"
fi
run 0 update-claude-plugins
if [[ $rc -eq 0 && "$args" == "--update" ]]; then
    pass "update-claude-plugins with no arguments runs plugins.sh --update and returns 0"
else
    die "update-claude-plugins with no arguments: rc=$rc args=${(q)args}"
fi

# --- Test 2: update-claude-config runs config.sh with the caller's
#     arguments and returns its status. ----------------------------------
run 5 update-claude-config --dry-run
if [[ $rc -eq 5 && "$args" == "--dry-run" && -z "$err" ]]; then
    pass "update-claude-config runs config.sh <args> and returns its status"
else
    die "update-claude-config: rc=$rc args=${(q)args} err=${(q)err}"
fi
run 0 update-claude-config
if [[ $rc -eq 0 && -z "$args" ]]; then
    pass "update-claude-config with no arguments runs config.sh with none and returns 0"
else
    die "update-claude-config with no arguments: rc=$rc args=${(q)args}"
fi

# --- Test 3: update_claude_plugins behaves as update-claude-plugins and
#     prints nothing of its own. -----------------------------------------
run 4 update_claude_plugins --dry-run
if [[ $rc -eq 4 && "$args" == $'--update\n--dry-run' && -z "$err" ]]; then
    pass "update_claude_plugins calls update-claude-plugins with no notice of its own"
else
    die "update_claude_plugins: rc=$rc args=${(q)args} err=${(q)err}"
fi

# --- Test 4: a script that is not executable is refused by path. --------
chmod 0644 "$HOME/.claude/plugins.sh" "$HOME/.claude/config.sh"
run 0 update-claude-plugins
if [[ $rc -ne 0 && -z "$args" \
    && "$err" == "update-claude-plugins: $HOME/.claude/plugins.sh is missing or not executable" ]]; then
    pass "update-claude-plugins refuses a non-executable plugins.sh, naming its path"
else
    die "update-claude-plugins with non-executable script: rc=$rc err=${(q)err}"
fi
run 0 update-claude-config
if [[ $rc -ne 0 && -z "$args" \
    && "$err" == "update-claude-config: $HOME/.claude/config.sh is missing or not executable" ]]; then
    pass "update-claude-config refuses a non-executable config.sh, naming its path"
else
    die "update-claude-config with non-executable script: rc=$rc err=${(q)err}"
fi

# --- Test 5: a missing script is refused by path. -----------------------
command rm -f "$HOME/.claude/plugins.sh" "$HOME/.claude/config.sh"
run 0 update-claude-plugins
if [[ $rc -ne 0 && "$err" == *"$HOME/.claude/plugins.sh is missing or not executable" ]]; then
    pass "update-claude-plugins refuses a missing plugins.sh, naming its path"
else
    die "update-claude-plugins with missing script: rc=$rc err=${(q)err}"
fi
run 0 update-claude-config
if [[ $rc -ne 0 && "$err" == *"$HOME/.claude/config.sh is missing or not executable" ]]; then
    pass "update-claude-config refuses a missing config.sh, naming its path"
else
    die "update-claude-config with missing script: rc=$rc err=${(q)err}"
fi

print
print -- "---"
print -- "pass=$pass fail=$fail"
if (( fail == 0 && pass > 0 )); then
    print -- "All claude update helper tests passed."
    exit 0
fi
print -- "Some claude update helper tests FAILED."
exit 1
