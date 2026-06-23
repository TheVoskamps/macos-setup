#!/usr/bin/env bash

# Shared helpers for Claude global-config repo management.
#
# ~/.claude/ is a real git checkout of
# https://github.com/TheVoskamps/claude-config.git.
#
# Fresh clones use the HTTPS URL (most users won't have an SSH key
# registered on the org/repo). An existing clone whose `origin` is the
# SSH form is recognized as ours and its SSH origin is left intact.
#
# The active branch and the SSH host alias used in the git remote URL
# are selected from the `[claude]` section of the single-winner
# `config.toml` (issue #156), resolved across tiers:
#
#   <external host tier>/config.toml   > highest priority
#   profiles/<profile>/config.toml     > reverse(profiles) order
#   default/config.toml  > lowest priority
#
# Resolution is per-key single-winner (highest tier with a non-empty
# value wins); no per-key merging beyond that.
#
# The `[claude]` section accepts two optional keys:
#
#   [claude]
#   branch = "main"               # Default: remote default branch.
#   hostname = "github.com"       # Default: github.com. Lets ~/.ssh/config
#                                 # select an IdentityFile per machine.
#
# Both keys are optional. Missing values fall back to defaults.
#
# This script is sourced (not executed). It depends on
# `scripts/config_common.sh` for `get_hostname` / `get_profiles` /
# `resolve_config_value`.

# Guard against double-sourcing.
if [[ -n "${CLAUDE_REPO_COMMON_LOADED:-}" ]]; then
    return 0
fi
CLAUDE_REPO_COMMON_LOADED=1

CLAUDE_REPO_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config_common.sh
source "$CLAUDE_REPO_COMMON_DIR/config_common.sh"

# --- Constants -------------------------------------------------------------

# Canonical SSH URL for the global Claude config repo. Env-overridable
# so the integration test under `scripts/test/` can point at a local
# fake remote without touching GitHub.
#
# When the env override is NOT in effect, `claude_repo_apply_config`
# may rewrite this URL to use a non-default SSH host alias parsed from
# config.toml's `[claude]` section (see `claude_repo_resolve_hostname`). We track
# whether the env override was set BEFORE applying defaults so that
# `apply_config` knows not to clobber a test-supplied URL.
_CLAUDE_REPO_URL_SSH_WAS_ENV="${CLAUDE_REPO_URL_SSH+set}"
_CLAUDE_REPO_URL_HTTPS_WAS_ENV="${CLAUDE_REPO_URL_HTTPS+set}"
: "${CLAUDE_REPO_URL_SSH:=git@github.com:TheVoskamps/claude-config.git}"

# HTTPS form, used for fresh clones (and accepted when detecting an
# existing checkout). Fresh clones use this URL because most users
# won't have an SSH key registered on the org/repo.
: "${CLAUDE_REPO_URL_HTTPS:=https://github.com/TheVoskamps/claude-config.git}"

# Default SSH host alias. config.toml's `[claude]` section's `hostname=` overrides this.
# Default `github.com` reproduces the canonical `CLAUDE_REPO_URL_SSH`
# defined above exactly, so existing detection keeps working unchanged
# for default users.
#
# Env-overridable so the integration test under `scripts/test/` can
# simulate a sandbox-local "default hostname" without touching real
# DNS / SSH config.
: "${CLAUDE_REPO_DEFAULT_HOSTNAME:=github.com}"

# Repo path component used when deriving SSH/HTTPS URLs from a hostname.
# Single source of truth so a future repo rename only touches one spot.
# Env-overridable for the integration test (so derived URLs point at
# the sandbox bare repo).
: "${CLAUDE_REPO_PATH:=TheVoskamps/claude-config.git}"

# Hostname currently in effect for URL derivation. Populated by
# `claude_repo_apply_config` from the parsed config.toml's `[claude]` section. Defaults
# to `github.com` so functions called before `apply_config` still
# behave correctly.
CLAUDE_REPO_HOSTNAME="$CLAUDE_REPO_DEFAULT_HOSTNAME"

# Local checkout location.
CLAUDE_DIR="$HOME/.claude"

# --- Output helpers --------------------------------------------------------
# `config_common.sh` (sourced above) already defines `info`/`success`/
# `error_exit`, so in normal use these `declare -F` checks are no-ops.
# The fallbacks exist as a defensive layer for stand-alone sourcing
# from tests or one-off scripts that load this file without first
# sourcing `config_common.sh`.

if ! declare -F info >/dev/null 2>&1; then
    info() { echo "-> $1"; }
fi
if ! declare -F success >/dev/null 2>&1; then
    success() { echo "[ok] $1"; }
fi
if ! declare -F error_exit >/dev/null 2>&1; then
    error_exit() { echo "Error: $1" >&2; exit 1; }
fi

# --- [claude] config.toml reads --------------------------------------------

# Resolved values from config.toml's `[claude]` section. Populated by
# `claude_repo_load_config`. Empty until then.
CLAUDE_REPO_CONFIG_BRANCH=""
CLAUDE_REPO_CONFIG_HOSTNAME=""

# Read the `[claude]` section of the resolved `config.toml` into
# `CLAUDE_REPO_CONFIG_BRANCH` and `CLAUDE_REPO_CONFIG_HOSTNAME`.
#
# The section is resolved per-key single-winner across tiers via
# `resolve_config_value` (host > reverse(profiles) > default). Both keys
# are optional; a missing key leaves the corresponding global empty.
#
# Querying is delegated to `dasel` (via `resolve_config_value`); we do
# not parse TOML by hand. `dasel` is a guaranteed bootstrap primitive.
#
# Args: repo_root
claude_repo_load_config() {
    local repo_root="$1"
    CLAUDE_REPO_CONFIG_BRANCH="$(resolve_config_value "$repo_root" "claude.branch")"
    CLAUDE_REPO_CONFIG_HOSTNAME="$(resolve_config_value "$repo_root" "claude.hostname")"
}

# --- URL derivation --------------------------------------------------------

# Derive an SSH URL of the canonical form for a given SSH host alias.
# Default hostname `github.com` reproduces the historical
# `CLAUDE_REPO_URL_SSH` exactly, so existing clones and detection logic
# keep working unchanged.
claude_repo_url_ssh_for() {
    local host="$1"
    echo "git@${host}:${CLAUDE_REPO_PATH}"
}

# Return the canonical HTTPS URL for the global Claude config repo.
# HTTPS doesn't go through `~/.ssh/config` host aliases, so this
# always uses the real `github.com` host regardless of any SSH alias
# configured via `hostname=`. This keeps `claude_repo_is_our_clone`
# accepting HTTPS clones regardless of which SSH alias is configured.
claude_repo_url_https_for() {
    echo "https://github.com/${CLAUDE_REPO_PATH}"
}

# Resolve the SSH hostname to use:
#   1. `hostname=` from the parsed config.toml's `[claude]` section if non-empty.
#   2. Otherwise, `CLAUDE_REPO_DEFAULT_HOSTNAME` (= `github.com`).
claude_repo_resolve_hostname() {
    if [[ -n "$CLAUDE_REPO_CONFIG_HOSTNAME" ]]; then
        echo "$CLAUDE_REPO_CONFIG_HOSTNAME"
    else
        echo "$CLAUDE_REPO_DEFAULT_HOSTNAME"
    fi
}

# Apply the parsed config.toml's `[claude]` section to module state:
#   - Set `CLAUDE_REPO_HOSTNAME` to the resolved hostname.
#   - If neither URL was set in the environment (test override),
#     re-derive `CLAUDE_REPO_URL_SSH` and `CLAUDE_REPO_URL_HTTPS` from
#     the resolved hostname. Env overrides win — tests that point at a
#     sandbox bare repo via `CLAUDE_REPO_URL_SSH=...` continue to work
#     unchanged.
#
# Args: repo_root
claude_repo_apply_config() {
    local repo_root="$1"
    claude_repo_load_config "$repo_root"

    CLAUDE_REPO_HOSTNAME=$(claude_repo_resolve_hostname)

    if [[ -z "$_CLAUDE_REPO_URL_SSH_WAS_ENV" ]]; then
        CLAUDE_REPO_URL_SSH=$(claude_repo_url_ssh_for "$CLAUDE_REPO_HOSTNAME")
    fi
    if [[ -z "$_CLAUDE_REPO_URL_HTTPS_WAS_ENV" ]]; then
        CLAUDE_REPO_URL_HTTPS=$(claude_repo_url_https_for)
    fi
}

# --- Safe-cwd wrapper for git network ops ----------------------------------

# Run `git <args>` from a freshly-created unique cwd, then return.
#
# Workaround for a macOS-specific hang in `git` network operations
# (`ls-remote`, `clone`, `fetch`, `pull`) when ALL of the following
# hold:
#
#   1. The shell's cwd has any descendant path that is the absolute
#      target of a symlink elsewhere on disk (anywhere — `~/.claude/`,
#      `/tmp/`, anywhere).
#   2. macOS has metadata for that target path (it currently exists
#      or did at some point).
#
# Under those conditions, `git` hangs ~2 minutes during SSH setup and
# eventually fails with "ssh: connect to host github.com port 22:
# Operation timed out". The mechanism is undocumented (likely
# something path-keyed inside Spotlight, APFS snapshots, fseventsd,
# or an EDR/MDM agent — `git fsmonitor` has been ruled out).
#
# Sidestepping condition (1) is the cheap fix: run the network op
# from a freshly-created `mktemp -d` directory that no preexisting
# symlink can be pointing into. Subshell isolation keeps the caller's
# cwd untouched. `mktemp -d` defaults to `$TMPDIR` (per-user
# `/var/folders/...`), which is not a popular symlink target.
#
# `/tmp` itself is NOT a safe choice — it's a popular symlink target.
#
# `-C "$CLAUDE_DIR"` and other git args pass through unchanged: the
# safe cwd is purely the shell's cwd at the time `git` runs; the
# actual git repo `git` operates on is still selected by `-C` (or by
# git's own discovery rules from the safe cwd, which won't find a
# repo there — so callers that omit `-C` MUST point at a remote URL,
# which all the affected network ops do).
#
# See issue #122.
git_in_safe_cwd() {
    local d
    d="$(mktemp -d)"
    ( cd "$d" && git "$@" )
    local rc=$?
    rmdir "$d" 2>/dev/null || true
    return $rc
}

# --- Repo detection --------------------------------------------------------

# Echo the URL git knows for the local repo's `origin` remote, or "" if
# the directory isn't a git repo at all.
claude_repo_origin_url() {
    local dir="$1"
    [[ -d "$dir/.git" ]] || return 0
    git -C "$dir" config --get remote.origin.url 2>/dev/null || true
}

# Return 0 if `$CLAUDE_DIR` is a clone of the global Claude config repo,
# 1 otherwise. Accepts SSH and HTTPS origin URLs in:
#
#   - the configured-hostname canonical form (`CLAUDE_REPO_URL_SSH`/
#     `CLAUDE_REPO_URL_HTTPS`, possibly env-overridden by tests or
#     re-derived by `claude_repo_apply_config` from a non-default
#     `hostname=` in config.toml's `[claude]` section);
#   - the default-hostname (`github.com`) canonical form, even when a
#     non-default hostname is configured. This keeps an existing clone
#     made before `hostname=` was set recognized as ours so the
#     install/update path can rewrite `origin` to the configured
#     hostname rather than migrate the directory aside.
claude_repo_is_our_clone() {
    local url
    url=$(claude_repo_origin_url "$CLAUDE_DIR")
    local default_ssh default_https
    default_ssh=$(claude_repo_url_ssh_for "$CLAUDE_REPO_DEFAULT_HOSTNAME")
    default_https=$(claude_repo_url_https_for)
    [[ "$url" == "$CLAUDE_REPO_URL_SSH" ]] \
        || [[ "$url" == "$CLAUDE_REPO_URL_HTTPS" ]] \
        || [[ "$url" == "$default_ssh" ]] \
        || [[ "$url" == "$default_https" ]]
}

# If `$CLAUDE_DIR`'s SSH `origin` URL uses the default hostname
# (`github.com`) but config.toml's `[claude]` section configures a different hostname,
# rewrite `origin` to the configured-hostname canonical SSH URL. No-op
# if the configured hostname is the default, if `origin` already uses
# the configured hostname, or if `origin` is HTTPS (HTTPS doesn't honor
# `~/.ssh/config` aliases).
#
# Idempotent on subsequent runs.
#
# Must be called AFTER `claude_repo_apply_config`, which populates
# `CLAUDE_REPO_HOSTNAME` and re-derives `CLAUDE_REPO_URL_SSH`.
claude_repo_reconcile_origin_hostname() {
    # Nothing to reconcile when configured hostname is the default.
    [[ "$CLAUDE_REPO_HOSTNAME" == "$CLAUDE_REPO_DEFAULT_HOSTNAME" ]] && return 0

    local url
    url=$(claude_repo_origin_url "$CLAUDE_DIR")
    [[ -z "$url" ]] && return 0

    # Already on the configured-hostname URL: idempotent no-op.
    [[ "$url" == "$CLAUDE_REPO_URL_SSH" ]] && return 0

    # Only reconcile when the existing origin is the default-hostname
    # SSH form. Don't touch HTTPS (no SSH alias to apply) or any
    # already-non-default SSH host.
    local default_ssh
    default_ssh=$(claude_repo_url_ssh_for "$CLAUDE_REPO_DEFAULT_HOSTNAME")
    if [[ "$url" != "$default_ssh" ]]; then
        return 0
    fi

    info "Rewriting origin to use configured SSH host alias: $url -> $CLAUDE_REPO_URL_SSH"
    git -C "$CLAUDE_DIR" remote set-url origin "$CLAUDE_REPO_URL_SSH"
}

# --- Branch resolution -----------------------------------------------------

# Resolve the configured branch from the parsed config.toml's `[claude]` section
# (must be loaded first via `claude_repo_load_config` /
# `claude_repo_apply_config`). Echoes the empty string when no
# `branch=` is set; callers fall back to the remote default branch.
claude_repo_resolve_configured_branch() {
    echo "$CLAUDE_REPO_CONFIG_BRANCH"
}

# Resolve the global repo's default branch dynamically via
# `git ls-remote --symref`. Falls back to `main` only if the lookup
# fails entirely.
claude_repo_default_branch_remote() {
    local out
    out=$(git_in_safe_cwd ls-remote --symref "$CLAUDE_REPO_URL_HTTPS" HEAD 2>/dev/null \
        | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
    if [[ -n "$out" ]]; then
        echo "$out"
    else
        echo "main"
    fi
}

# Resolve the default branch from an existing local checkout's
# `origin/HEAD`. If that's missing (e.g. clone done with `--single-branch`),
# falls back to a remote lookup.
claude_repo_default_branch_local() {
    local head
    head=$(git -C "$CLAUDE_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
    if [[ -n "$head" ]]; then
        echo "${head#origin/}"
        return 0
    fi
    claude_repo_default_branch_remote
}

# Resolve the target branch we want `~/.claude` checked out on:
#
#   1. Read the configured branch from config.toml's `[claude]` section `branch=`. If
#      it names a branch that exists on the remote, use it.
#   2. Otherwise (missing / empty / unknown branch), use the remote
#      default branch.
#
# If `~/.claude` is already a clone, prefer its `origin/HEAD` for the
# default lookup so we don't pay a network round-trip on every call.
#
# Callers must invoke `claude_repo_apply_config "$repo_root"` (or at
# least `claude_repo_load_config`) before calling this so the parsed
# `branch=` value is available.
claude_repo_resolve_target_branch() {
    local configured
    configured=$(claude_repo_resolve_configured_branch)

    local default_branch
    if claude_repo_is_our_clone; then
        default_branch=$(claude_repo_default_branch_local)
    else
        default_branch=$(claude_repo_default_branch_remote)
    fi

    if [[ -z "$configured" ]]; then
        echo "$default_branch"
        return 0
    fi

    # If the configured branch names a real remote branch, use it.
    # Otherwise fall back to the default branch (the configured value
    # is an unknown-branch hint; do not error).
    if claude_repo_is_our_clone; then
        if git -C "$CLAUDE_DIR" rev-parse --verify "refs/remotes/origin/$configured" >/dev/null 2>&1; then
            echo "$configured"
            return 0
        fi
        # Could be a brand-new branch we haven't fetched yet; check the
        # remote directly.
        if git_in_safe_cwd ls-remote --exit-code --heads "$CLAUDE_REPO_URL_HTTPS" "$configured" >/dev/null 2>&1; then
            echo "$configured"
            return 0
        fi
        echo "$default_branch"
        return 0
    fi
    if git_in_safe_cwd ls-remote --exit-code --heads "$CLAUDE_REPO_URL_SSH" "$configured" >/dev/null 2>&1; then
        echo "$configured"
    else
        echo "$default_branch"
    fi
}

# --- Stash helpers ---------------------------------------------------------

# Generate the canonical stash name for a (branch, timestamp) pair.
# We grep for `claude-install/` to surface stashes in error output.
claude_repo_stash_name() {
    local branch="$1"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    echo "claude-install/${branch}/${ts}"
}

# Push a named stash for the current branch if the working tree is
# dirty. Echoes the stash name on success, "" if nothing was stashed.
# Returns non-zero only on git failure.
claude_repo_stash_dirty() {
    local branch="$1"
    if git -C "$CLAUDE_DIR" diff --quiet \
        && git -C "$CLAUDE_DIR" diff --cached --quiet \
        && [[ -z "$(git -C "$CLAUDE_DIR" ls-files --others --exclude-standard)" ]]; then
        echo ""
        return 0
    fi
    local name
    name=$(claude_repo_stash_name "$branch")
    if ! git -C "$CLAUDE_DIR" stash push --include-untracked --message "$name" >/dev/null; then
        echo ""
        return 1
    fi
    echo "$name"
}

# Find the most recent stash whose message matches
# `claude-install/<branch>/...` and pop it. Aborts the operation with
# diagnostics if `git stash pop` fails (likely a conflict).
#
# Args: branch
claude_repo_pop_for_branch() {
    local branch="$1"
    local stash_ref=""
    # Run pipeline tolerantly: `grep` returns 1 if no match, which
    # under `set -o pipefail` would propagate as a script-level
    # failure even though "no matching stash" is the common case.
    stash_ref=$(git -C "$CLAUDE_DIR" stash list 2>/dev/null \
        | { grep -F "claude-install/${branch}/" || true; } \
        | head -n1 \
        | awk -F: '{print $1}')
    if [[ -z "$stash_ref" ]]; then
        return 0
    fi
    info "Restoring stashed changes for branch '$branch' ($stash_ref)..."
    if ! git -C "$CLAUDE_DIR" stash pop "$stash_ref"; then
        claude_repo_abort_stash_conflict "$branch" "$stash_ref"
    fi
}

# Print recovery instructions for a stash-pop conflict and exit.
claude_repo_abort_stash_conflict() {
    local branch="$1"
    local stash_ref="$2"
    echo
    echo "Error: stash pop conflicted on branch '$branch'." >&2
    echo "       The Claude config update was aborted." >&2
    echo >&2
    echo "Branch:     $branch" >&2
    echo "Stash ref:  $stash_ref" >&2
    echo >&2
    echo "git status (in $CLAUDE_DIR):" >&2
    git -C "$CLAUDE_DIR" status >&2 || true
    echo >&2
    echo "Other claude-install stashes still in place:" >&2
    git -C "$CLAUDE_DIR" stash list | grep -F "claude-install/" >&2 || echo "  (none)" >&2
    echo >&2
    echo "To recover:" >&2
    echo "  cd $CLAUDE_DIR" >&2
    echo "  # resolve the conflict by hand, then drop the stash:" >&2
    echo "  git stash drop $stash_ref" >&2
    echo "  # or, to discard the stashed changes entirely:" >&2
    echo "  git checkout -- . && git stash drop $stash_ref" >&2
    exit 1
}
