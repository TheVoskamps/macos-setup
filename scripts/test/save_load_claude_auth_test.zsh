#!/usr/bin/env zsh

# Functional tests for save_claude_auth / load_claude_auth (issue #49).
#
# The pair lives in profiles/claude-code-aliases/aliases.zsh. They swap
# the two pieces of Claude Code account identity -- the Keychain item
# "Claude Code-credentials" and the .oauthAccount block of ~/.claude.json
# -- to and from per-account backups ("Claude Code-credentials-<account>"
# and ~/.claude.json.<account>).
#
# In the style of cr_test.zsh (real git, stubbed claude), these tests use
# the REAL jq binary and a stubbed `security` function backed by a plain
# directory of files (one file per Keychain service name), so the real
# login Keychain is never touched. HOME is pointed at a per-case temp dir
# so ~/.claude.json and its sidecars land there, never in the real home.
#
# Each case runs in a `( ... )` subshell so the HOME override and the
# stub never leak into the next case.

emulate -L zsh
set -u

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
PROFILE="$REPO_ROOT/profiles/claude-code-aliases/aliases.zsh"

if [[ ! -r "$PROFILE" ]]; then
    print -- "FAIL: cannot read $PROFILE" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    print -- "FAIL: jq not on PATH (core-tier dependency)" >&2
    exit 1
fi

# Unlike cr_test.zsh, the assertions here run INSIDE the per-case
# subshells (they need the case's HOME/SEC_DIR), so plain counter
# variables would not propagate back. pass/die record marker files in a
# parent-owned dir instead, and the parent counts those at the end.
COUNT_DIR="$(mktemp -d)"
trap 'rm -rf "$COUNT_DIR"' EXIT
pass () { print -- "PASS: $1"; mktemp "$COUNT_DIR/pass.XXXXXX" >/dev/null }
die  () { print -- "FAIL: $1"; mktemp "$COUNT_DIR/fail.XXXXXX" >/dev/null }

# --- The security stub. Defined as a string and eval'd inside each
#     subshell (after sourcing the profile) so every case gets it.
#     State: one file per service name under $SEC_DIR. find with no
#     matching file returns 44, security's real "not found" status.
SECURITY_STUB='
security () {
    local cmd="$1"; shift
    local svc="" pwval=""
    while (( $# )); do
        case "$1" in
            -s) svc="$2"; shift 2 ;;
            -a) shift 2 ;;
            -w) if (( $# > 1 )); then pwval="$2"; shift 2; else shift; fi ;;
            -U) shift ;;
            *)  shift ;;
        esac
    done
    case "$cmd" in
        find-generic-password)
            [[ -f "$SEC_DIR/$svc" ]] || return 44
            cat "$SEC_DIR/$svc"
            ;;
        add-generic-password)
            print -r -- "$pwval" > "$SEC_DIR/$svc"
            ;;
        *) return 1 ;;
    esac
}
'

# Seed a "logged in" state for account $1 (email) $2 (uuid) $3 (token).
seed_login () {
    print -r -- "$3" > "$SEC_DIR/Claude Code-credentials"
    jq -n --arg e "$1" --arg u "$2" \
        '{numStartups: 7, oauthAccount: {emailAddress: $e, accountUuid: $u}}' \
        > "$HOME/.claude.json"
}

new_case () {
    # Usage: eval "$(new_case)" inside a subshell: sets HOME + SEC_DIR.
    print 'export HOME="$(mktemp -d)"; export SEC_DIR="$HOME/sec"; mkdir -p "$SEC_DIR"'
}

# --- Test 1: save with no --account saves the built-in default:
#     Keychain backup + 0400 sidecar. -------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    if ! save_claude_auth 2>/dev/null; then
        die "save default: returned non-zero"
    elif [[ "$(cat "$SEC_DIR/Claude Code-credentials-default" 2>/dev/null)" != "tok-a" ]]; then
        die "save default: Keychain backup missing or wrong"
    elif [[ "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json.default" 2>/dev/null)" != "a@x.com" ]]; then
        die "save default: sidecar missing or wrong"
    elif [[ "$(stat -f '%Lp' "$HOME/.claude.json.default")" != "400" ]]; then
        die "save default: sidecar not 0400"
    else
        pass "save with no --account saves the built-in default (Keychain + 0400 sidecar)"
    fi
)

# --- Test 2: --account default rejected on both save and load. -----------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    if save_claude_auth --account default 2>/dev/null; then
        die "save --account default: was accepted"
    elif load_claude_auth --account default 2>/dev/null; then
        die "load --account default: was accepted"
    else
        pass "--account default rejected on both save and load"
    fi
)

# --- Test 3: save refuses to overwrite without --force (default and
#     named), and --force overwrites. -------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    save_claude_auth 2>/dev/null
    save_claude_auth --account work 2>/dev/null
    if save_claude_auth 2>/dev/null; then
        die "save default overwrite: no --force but succeeded"
    elif save_claude_auth --account work 2>/dev/null; then
        die "save named overwrite: no --force but succeeded"
    else
        pass "save refuses to overwrite an existing profile without --force"
    fi
    seed_login b@x.com uuid-b tok-b
    if save_claude_auth --account work --force 2>/dev/null \
        && [[ "$(cat "$SEC_DIR/Claude Code-credentials-work")" == "tok-b" ]] \
        && [[ "$(jq -r '.oauthAccount.accountUuid' "$HOME/.claude.json.work")" == "uuid-b" ]]; then
        pass "save --force overwrites an existing profile (both halves)"
    else
        die "save --force: overwrite failed"
    fi
)

# --- Test 4: save fails clearly when not logged in. ----------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    err="$(save_claude_auth 2>&1)"
    if [[ $? -ne 0 && "$err" == *"not currently logged in"* ]]; then
        pass "save fails clearly when not logged in (no Keychain item)"
    else
        die "save when not logged in: expected failure naming the cause"
    fi
)

# --- Test 5: load with no --account fails loudly when the built-in
#     default has never been saved. ---------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    err="$(load_claude_auth 2>&1)"
    if [[ $? -ne 0 && "$err" == *"no built-in default saved yet"* ]]; then
        pass "load with no --account fails loudly when default never saved"
    else
        die "load with unsaved default: expected loud failure"
    fi
)

# --- Test 6: round trip -- save two accounts, load each back; both
#     halves restored, unrelated ~/.claude.json keys preserved. -----------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    save_claude_auth 2>/dev/null
    seed_login b@x.com uuid-b tok-b
    save_claude_auth --account work 2>/dev/null
    load_claude_auth 2>/dev/null   # back to the built-in default
    if [[ "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-a" ]] \
        && [[ "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" == "a@x.com" ]] \
        && [[ "$(jq -r '.numStartups' "$HOME/.claude.json")" == "7" ]]; then
        pass "load restores both halves and preserves unrelated ~/.claude.json keys"
    else
        die "load round trip: wrong token, oauthAccount, or clobbered keys"
    fi
    load_claude_auth --account work 2>/dev/null
    if [[ "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-b" ]] \
        && [[ "$(jq -r '.oauthAccount.accountUuid' "$HOME/.claude.json")" == "uuid-b" ]]; then
        pass "load --account <name> restores a named profile"
    else
        die "load named: both halves not restored"
    fi
)

# --- Test 7: load fails clearly when the sidecar or the Keychain entry
#     is missing. ---------------------------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    err="$(load_claude_auth --account nosuch 2>&1)"
    if [[ $? -ne 0 && "$err" == *"no saved account 'nosuch'"* ]]; then
        pass "load names the missing sidecar"
    else
        die "load with missing sidecar: expected clear failure"
    fi
    save_claude_auth --account work 2>/dev/null
    command rm -f "$SEC_DIR/Claude Code-credentials-work"
    err="$(load_claude_auth --account work 2>&1)"
    if [[ $? -ne 0 && "$err" == *"no Keychain entry for 'work'"* ]]; then
        pass "load names the missing Keychain entry"
    else
        die "load with missing Keychain entry: expected clear failure"
    fi
)

# --- Test 8: name validation -- bad charset rejected, email accepted,
#     --account with no value rejected. -----------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    if save_claude_auth --account 'bad/name' 2>/dev/null; then
        die "name validation: 'bad/name' accepted on save"
    elif load_claude_auth --account 'bad name' 2>/dev/null; then
        die "name validation: 'bad name' accepted on load"
    else
        pass "names outside ^[A-Za-z0-9._@-]+\$ are rejected"
    fi
    if save_claude_auth --account 'me+work@example.com' 2>/dev/null; then
        die "name validation: '+' accepted (outside the charset)"
    else
        pass "a name with a character outside the charset (+) is rejected"
    fi
    if save_claude_auth --account 'me.work@example.com' 2>/dev/null \
        && [[ -f "$HOME/.claude.json.me.work@example.com" ]]; then
        pass "an account email works verbatim as the name"
    else
        die "name validation: plain email rejected"
    fi
    if save_claude_auth --account 2>/dev/null; then
        die "--account with no value accepted on save"
    elif load_claude_auth --account 2>/dev/null; then
        die "--account with no value accepted on load"
    else
        pass "--account with no following value is rejected"
    fi
)

# --- Test 9: unknown arguments rejected by name, non-zero. ---------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    err="$(save_claude_auth --acount work 2>&1)"
    rc=$?
    err2="$(load_claude_auth extra 2>&1)"
    rc2=$?
    if (( rc != 0 && rc2 != 0 )) \
        && [[ "$err" == *"unknown argument: --acount"* ]] \
        && [[ "$err2" == *"unknown argument: extra"* ]]; then
        pass "unknown arguments are rejected by name with non-zero status"
    else
        die "unknown-argument rejection wrong"
    fi
)

# --- Test 10: load refuses to clobber an unsaved live identity, and
#     proceeds with --force. ----------------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    save_claude_auth --account work 2>/dev/null
    seed_login c@x.com uuid-c tok-c      # live identity never saved
    err="$(load_claude_auth --account work 2>&1)"
    if [[ $? -ne 0 && "$err" == *"never saved"* \
        && "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-c" ]]; then
        pass "load aborts when the live identity matches no sidecar"
    else
        die "load did not protect the unsaved live identity"
    fi
    if load_claude_auth --account work --force 2>/dev/null \
        && [[ "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-a" ]]; then
        pass "load --force discards the unsaved identity and proceeds"
    else
        die "load --force did not proceed"
    fi
)

# --- Test 11: a failed Keychain backup write makes save fail loudly
#     with nothing saved -- no sidecar, no "saved" message. ---------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    functions[security_orig]=$functions[security]
    security () {
        [[ "$1" == "add-generic-password" ]] && return 1
        security_orig "$@"
    }
    seed_login a@x.com uuid-a tok-a
    err="$(save_claude_auth --account work 2>&1)"
    if [[ $? -ne 0 && "$err" == *"FAILED"* && "$err" != *"saved 'work'"* \
        && ! -e "$HOME/.claude.json.work" ]]; then
        pass "save fails loudly on a Keychain write failure, writing no sidecar"
    else
        die "save with a failing Keychain write did not fail loudly with nothing saved"
    fi
)

# --- Test 12: load with a corrupt ~/.claude.json refuses up front --
#     nothing changed: Keychain untouched, JSON untouched, no temp
#     leftover under $HOME. ------------------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    seed_login a@x.com uuid-a tok-a
    save_claude_auth --account work 2>/dev/null
    print -- "not json" > "$HOME/.claude.json"
    err="$(load_claude_auth --account work 2>&1)"
    rc=$?
    leftovers=( "$HOME"/.claude.json-new.*(N) )
    if [[ $rc -ne 0 && "$err" == *"nothing changed"* \
        && "$err" != *"switched to"* \
        && "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-a" \
        && "$(cat "$HOME/.claude.json")" == "not json" ]] \
        && (( ${#leftovers} == 0 )); then
        pass "load refuses a corrupt ~/.claude.json with nothing changed"
    else
        die "load with corrupt ~/.claude.json did not refuse cleanly"
    fi
)

# --- Test 13: a failed live-Keychain write makes load fail loudly,
#     leaving both halves unchanged. ---------------------------------------
(
    eval "$(new_case)"; source "$PROFILE"; eval "$SECURITY_STUB"
    functions[security_orig]=$functions[security]
    security () {
        if [[ "$1" == "add-generic-password" ]]; then
            local -i i
            for (( i = 2; i <= $#; i++ )); do
                if [[ "${@[i]}" == "-s" && "${@[i+1]}" == "Claude Code-credentials" ]]; then
                    return 1
                fi
            done
        fi
        security_orig "$@"
    }
    seed_login a@x.com uuid-a tok-a
    save_claude_auth --account work 2>/dev/null
    seed_login b@x.com uuid-b tok-b
    save_claude_auth --account other 2>/dev/null
    err="$(load_claude_auth --account work 2>&1)"
    rc=$?
    leftovers=( "$HOME"/.claude.json-new.*(N) )
    if [[ $rc -ne 0 && "$err" == *"both unchanged"* \
        && "$err" != *"switched to"* \
        && "$(cat "$SEC_DIR/Claude Code-credentials")" == "tok-b" \
        && "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" == "b@x.com" ]] \
        && (( ${#leftovers} == 0 )); then
        pass "load fails loudly on a live-Keychain write failure, both halves unchanged"
    else
        die "load with a failing live-Keychain write did not fail cleanly"
    fi
)

pass=( "$COUNT_DIR"/pass.*(N) )
fail=( "$COUNT_DIR"/fail.*(N) )
print
print -- "---"
print -- "pass=${#pass} fail=${#fail}"
if (( ${#fail} == 0 && ${#pass} > 0 )); then
    print -- "All save/load_claude_auth tests passed."
    exit 0
fi
print -- "Some save/load_claude_auth tests FAILED."
exit 1
