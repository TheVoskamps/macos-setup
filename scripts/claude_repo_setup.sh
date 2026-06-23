#!/usr/bin/env bash

# Manage `~/.claude/` as a real clone of the global Claude config repo.
#
# Sub-commands:
#
#   install   Set up `~/.claude/` from the global repo. Two states:
#               1) `~/.claude/` is already our clone -> stash, pull,
#                  switch branch if needed, restore stash.
#               2) anything else -> if it exists, move aside to
#                  `~/.claude.orig.<ts>/`; fresh-clone; overlay the
#                  captured contents (excluding .git, local wins) onto
#                  the new clone. If it doesn't exist, just clone.
#
#   update    Update an existing clone (state 1 only). Errors loudly if
#             `~/.claude/` is missing or isn't our repo.
#
#   outdated  Read-only check: fetch, then show pending pulls/pushes
#             and any dirty files.
#
#   plugins-install  Sync Claude plugins by invoking the clone's own
#                    `~/.claude/plugins.sh --install` (registers the
#                    marketplaces and installs the enabled plugins
#                    declared in the clone's settings.json). This repo
#                    only CALLS plugins.sh; the settings.json parsing
#                    and `claude plugin` invocations live in the
#                    claude-config repo.
#
#   plugins-update   Same as plugins-install but `--update`: updates the
#                    registered marketplaces and installed plugins.
#
# `install` / `update` also run the plugin sync inline (install ->
# plugins-install, update -> plugins-update) AFTER the clone is in
# place. Inline, the sync is non-fatal: a missing `claude` binary, a
# missing `~/.claude/plugins.sh` (an older clone predating the
# plugins refactor), or a non-zero exit from plugins.sh prints a
# warning and is skipped/ignored rather than aborting the install /
# update flow. The standalone `plugins-install` / `plugins-update`
# sub-commands surface a plugins.sh non-zero exit so a directly-invoked
# run reports failure (the missing-binary / missing-script guards still
# warn-and-skip with success).
#
# Branch and SSH host alias selection are resolved per-key single-winner
# (host > reverse(profiles) > default) from the `[claude]` section of
# config.toml, via `scripts/claude_repo_common.sh`. Missing / empty /
# unknown branch falls back to the global repo's default branch (resolved
# at run time). Missing hostname defaults to `github.com`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=claude_repo_common.sh
source "$SCRIPT_DIR/claude_repo_common.sh"

# --- Sub-command dispatch --------------------------------------------------

usage() {
    cat <<'EOF'
Usage: claude_repo_setup.sh {install|update|outdated|plugins-install|plugins-update}

  install          Provision `~/.claude/` from the global Claude config
                   repo. Handles fresh installs, existing clones, and
                   migration of any pre-existing `~/.claude/` that isn't
                   a clone of the target repo. Then runs the plugin sync
                   (non-fatal).
  update           Update an existing `~/.claude/` clone (no migration).
                   Then runs the plugin sync (non-fatal).
  outdated         Read-only: show pending pulls/pushes and dirty files.
  plugins-install  Invoke `~/.claude/plugins.sh --install` directly
                   (surfaces a non-zero exit).
  plugins-update   Invoke `~/.claude/plugins.sh --update` directly
                   (surfaces a non-zero exit).
EOF
}

CMD="${1:-}"
case "$CMD" in
    install|update|outdated|plugins-install|plugins-update) ;;
    -h|--help|"") usage; [[ -z "$CMD" ]] && exit 1 || exit 0 ;;
    *) usage >&2; exit 1 ;;
esac

# --- Shared helpers (depend on `info` / `success` from common) -------------

# Print branches and current state of the local checkout. Cheap, used
# at the end of `install` / `update` for visibility.
print_repo_state() {
    echo
    info "Current branch and remotes for $CLAUDE_DIR:"
    git -C "$CLAUDE_DIR" branch --all || true
    echo
    info "Active branch:"
    git -C "$CLAUDE_DIR" symbolic-ref --short HEAD || true
    echo
    info "Working tree status:"
    git -C "$CLAUDE_DIR" status -sb || true
}

# Switch to `target_branch`, creating a tracking branch if needed. The
# working tree is expected to be clean (caller stashes first). If the
# branch already exists locally, we just `git switch`. If only the
# remote-tracking ref exists, we create the local branch from it. If
# neither exists, we fetch the branch first.
switch_to_branch() {
    local target_branch="$1"
    local current
    current=$(git -C "$CLAUDE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [[ "$current" == "$target_branch" ]]; then
        return 0
    fi

    info "Switching from '${current:-<detached>}' to '$target_branch'..."

    if git -C "$CLAUDE_DIR" rev-parse --verify --quiet "refs/heads/$target_branch" >/dev/null; then
        git -C "$CLAUDE_DIR" switch "$target_branch"
        return 0
    fi
    if git -C "$CLAUDE_DIR" rev-parse --verify --quiet "refs/remotes/origin/$target_branch" >/dev/null; then
        git -C "$CLAUDE_DIR" switch -c "$target_branch" --track "origin/$target_branch"
        return 0
    fi

    # Branch isn't known locally yet; fetch it explicitly.
    git_in_safe_cwd -C "$CLAUDE_DIR" fetch origin "$target_branch":"refs/remotes/origin/$target_branch"
    git -C "$CLAUDE_DIR" switch -c "$target_branch" --track "origin/$target_branch"
}

# Fast-forward the current branch, stashing any dirty changes first
# under a branch-keyed name and popping them on success. Conflicts on
# pop call `claude_repo_abort_stash_conflict` and exit.
#
# The pull itself is non-fatal: a transient network blip, an
# unexpectedly non-fast-forward upstream, or auth failure prints a
# warning but does NOT abort the script. This keeps `make ai` from
# failing the whole install over a recoverable hiccup, while still
# making the failure visible.
pull_with_stash() {
    local branch
    branch=$(git -C "$CLAUDE_DIR" symbolic-ref --short HEAD)

    local stash_name
    stash_name=$(claude_repo_stash_dirty "$branch")
    if [[ -n "$stash_name" ]]; then
        info "Stashed dirty working tree on '$branch' as: $stash_name"
    fi

    info "Fast-forwarding '$branch'..."
    local rc=0
    git_in_safe_cwd -C "$CLAUDE_DIR" pull --ff-only --rebase=false || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "Warning: 'git pull --ff-only' on '$branch' failed (exit $rc); continuing." >&2
    fi

    if [[ -n "$stash_name" ]]; then
        # The stash we just made is at the top, but match by branch
        # name to be defensive against concurrent operations.
        claude_repo_pop_for_branch "$branch"
    fi
}

# --- Claude plugin sync ----------------------------------------------------

# Path to the plugin-sync script that ships WITH the clone. The
# claude-config repo owns `plugins.sh`; this repo only locates and
# invokes it. Env-overridable so the integration test can point at a
# fake script without a real clone.
: "${CLAUDE_PLUGINS_SCRIPT:=$CLAUDE_DIR/plugins.sh}"

# Name of the `claude` CLI binary. Env-overridable so the integration
# test can substitute a stub on PATH (or point at a guaranteed-absent
# name to exercise the missing-binary guard).
: "${CLAUDE_CLI_BIN:=claude}"

# Sync Claude plugins by invoking the clone's own `plugins.sh` with the
# given flag (`--install` or `--update`). All settings.json parsing and
# `claude plugin` invocations live in the claude-config repo's
# `plugins.sh`; this function only locates and calls it.
#
# Guards (warn + skip, treated as SUCCESS):
#   - the `claude` CLI is not on PATH (fresh install ordering, or a
#     machine without the CLI yet);
#   - `$CLAUDE_PLUGINS_SCRIPT` is missing (an older claude-config
#     checkout predating the plugins refactor).
#
# On a real invocation, the plugins.sh exit code is returned to the
# caller. The caller decides whether that is fatal:
#   - the install / update FLOW calls this non-fatally (warns on a
#     non-zero exit but does not abort), matching `pull_with_stash`;
#   - the standalone `plugins-install` / `plugins-update` sub-commands
#     return the exit code so a directly-invoked run reports failure.
#
# Args: flag (`--install` | `--update`)
sync_claude_plugins() {
    local flag="$1"

    if ! command -v "$CLAUDE_CLI_BIN" >/dev/null 2>&1; then
        echo "Warning: '$CLAUDE_CLI_BIN' not on PATH; skipping plugin sync ($flag)." >&2
        return 0
    fi
    if [[ ! -f "$CLAUDE_PLUGINS_SCRIPT" ]]; then
        echo "Warning: $CLAUDE_PLUGINS_SCRIPT not found; skipping plugin sync ($flag)." >&2
        echo "         (Older claude-config checkout predating the plugins refactor?)" >&2
        return 0
    fi

    info "Syncing Claude plugins via $CLAUDE_PLUGINS_SCRIPT $flag..."
    local rc=0
    bash "$CLAUDE_PLUGINS_SCRIPT" "$flag" || rc=$?
    return $rc
}

# Non-fatal wrapper for the install / update FLOW: run the plugin sync
# for the given flag and warn (do not abort) on a non-zero exit. The
# missing-binary / missing-script guards inside `sync_claude_plugins`
# already return 0, so this only ever warns on a genuine plugins.sh
# failure.
#
# Args: flag (`--install` | `--update`)
sync_claude_plugins_nonfatal() {
    local flag="$1"
    local rc=0
    sync_claude_plugins "$flag" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "Warning: plugin sync ($flag) failed (exit $rc); continuing." >&2
    fi
}

# --- Install paths ---------------------------------------------------------

# State 1: `~/.claude/` is already our clone. Sync the current branch,
# switch to target if needed, then sync the target branch.
install_existing_clone() {
    local target_branch="$1"

    info "Detected existing clone at $CLAUDE_DIR (origin matches)."

    # If the `[claude]` hostname configures a non-default SSH
    # host alias and `origin` is still on the default-hostname URL,
    # rewrite `origin` to use the alias so subsequent network ops pick
    # the right `~/.ssh/config` IdentityFile. Idempotent.
    claude_repo_reconcile_origin_hostname

    local current
    current=$(git -C "$CLAUDE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")

    # Fetch once up front. `pull_with_stash` issues `git pull` which
    # would re-fetch, but doing an explicit prune-fetch first keeps the
    # remote-tracking refs tidy in the no-pull-needed cases too.
    info "Fetching origin..."
    git_in_safe_cwd -C "$CLAUDE_DIR" fetch origin --prune

    # Sync the current branch first (cheaper than switching cold).
    if [[ -n "$current" ]]; then
        pull_with_stash
    else
        info "Detached HEAD detected; skipping pre-switch pull."
    fi

    if [[ -z "$current" ]] || [[ "$current" != "$target_branch" ]]; then
        # Stash any dirt on the current branch before switching: a
        # working-tree state belongs to `current`, not `target_branch`.
        if [[ -n "$current" ]]; then
            local pre_switch_stash=""
            pre_switch_stash=$(claude_repo_stash_dirty "$current")
            if [[ -n "$pre_switch_stash" ]]; then
                info "Stashed working tree on '$current' before switch as: $pre_switch_stash"
            fi
        fi
        switch_to_branch "$target_branch"
        # Pop any matching stash for the target branch (left over from
        # a previous run on the same branch), then sync.
        claude_repo_pop_for_branch "$target_branch"
        pull_with_stash
    fi
}

# Overlay every entry under `$src` (excluding `.git`) onto `$dst`.
# Local wins: if `$dst` already has the entry, it is overwritten. After
# this runs, the user can use `git status` in `$dst` to see what their
# machine had vs. the fresh clone.
#
# Per-entry rules (applied to each top-level entry under `$src`):
#
#   - `.git`:           skip.
#   - Broken symlink    (target doesn't resolve): skip; warn with
#                       source path + dead target. Do not copy a broken
#                       pointer onto the clone.
#   - Valid symlink:    copy as a symlink (`cp -RP`). Preserves user
#                       intent.
#   - Regular file:     copy, overwriting the clone's version.
#   - Directory:        deep-merge with local-wins (existing behavior).
#
# Kind-mismatch handling: BSD `cp` on macOS does not replace a
# destination of a different kind. `cp -p file existing-dir/` copies
# INTO the directory, `cp -RP symlink existing-dir/` copies INTO the
# directory, and `cp -RP src existing-symlink` follows the destination
# symlink rather than replacing it. To preserve "local wins", we detect
# any kind mismatch (or destination symlink) up front and remove the
# destination so the copy replaces cleanly. Same-kind directory and
# file collisions keep the current behavior: `cp -p` overwrites a file
# with a file, and `cp -R src/. dst/` deep-merges directory onto
# directory with local wins.
overlay_orig_onto_clone() {
    local src="$1"
    local dst="$2"
    info "Overlaying $src onto $dst (excluding .git)..."
    local entry
    while IFS= read -r -d '' entry; do
        local name
        name="$(basename "$entry")"
        [[ "$name" == ".git" ]] && continue
        local target="$dst/$name"

        # Skip dangling symlinks: a broken pointer in `$src` would
        # otherwise replace the clone's real file/dir at the same path
        # with a dead symlink. We test `-L` (symlink) AND not `-e` (the
        # link target doesn't resolve). Warn so the user notices and
        # can investigate the source path under `.claude.orig.<ts>/`.
        if [[ -L "$entry" ]] && [[ ! -e "$entry" ]]; then
            local dead_target
            dead_target=$(readlink "$entry" 2>/dev/null || echo "<unreadable>")
            echo "Warning: skipping broken symlink: $entry -> $dead_target" >&2
            continue
        fi

        # Classify source and destination as L (symlink), D (directory,
        # not symlink), or F (everything else). Order matters: `-L`
        # first so a symlink-to-directory is L, not D.
        local src_kind dst_kind
        if   [[ -L "$entry"  ]]; then src_kind=L
        elif [[ -d "$entry"  ]]; then src_kind=D
        else                          src_kind=F
        fi
        if   [[ -L "$target" ]]; then dst_kind=L
        elif [[ -d "$target" ]]; then dst_kind=D
        elif [[ -e "$target" ]]; then dst_kind=F
        else                          dst_kind=
        fi

        # Remove the destination first when:
        #   - kinds differ (BSD `cp` would copy INTO an existing
        #     directory, or `mkdir -p` would fail on a regular file);
        #   - the destination is a symlink (BSD `cp` would follow it
        #     and clobber whatever it points to instead of replacing
        #     the symlink itself).
        # Same-kind D->D and F->F fall through to the existing logic,
        # which is the intentional deep-merge / overwrite that keeps
        # "local wins" within a directory subtree.
        if [[ -n "$dst_kind" ]] \
            && { [[ "$src_kind" != "$dst_kind" ]] || [[ "$dst_kind" == L ]]; }
        then
            rm -rf "$target"
        fi

        if [[ "$src_kind" == L ]]; then
            cp -RP "$entry" "$target"
        elif [[ "$src_kind" == D ]]; then
            mkdir -p "$target"
            cp -R "$entry"/. "$target"/
        else
            cp -p "$entry" "$target"
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# State 2 (existing dir): `$CLAUDE_DIR` exists but isn't our clone.
# Move aside, fresh-clone, overlay captured contents.
install_migrate_existing() {
    local target_branch="$1"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local orig_dir="${CLAUDE_DIR}.orig.${timestamp}"

    info "Detected existing $CLAUDE_DIR that is not a clone of $CLAUDE_REPO_URL_HTTPS."

    info "Moving aside: $CLAUDE_DIR -> $orig_dir"
    mv "$CLAUDE_DIR" "$orig_dir"

    info "Cloning $CLAUDE_REPO_URL_HTTPS into $CLAUDE_DIR..."
    git_in_safe_cwd clone "$CLAUDE_REPO_URL_HTTPS" "$CLAUDE_DIR"

    switch_to_branch "$target_branch"

    overlay_orig_onto_clone "$orig_dir" "$CLAUDE_DIR"

    echo
    success "Migrated to global-repo layout."
    echo "Your previous ~/.claude/ contents are preserved at: $orig_dir"
    echo
    echo "Overlaid files appear as dirty in 'git -C ~/.claude status' by design."
    echo "Use git diff/git status in ~/.claude to inspect, then decide to commit,"
    echo "branch, or discard them."
}

# State 2 (no dir): `$CLAUDE_DIR` doesn't exist. Fresh clone.
install_fresh_clone() {
    local target_branch="$1"

    info "No $CLAUDE_DIR found. Cloning fresh..."
    git_in_safe_cwd clone "$CLAUDE_REPO_URL_HTTPS" "$CLAUDE_DIR"
    switch_to_branch "$target_branch"
}

# --- Top-level command implementations -------------------------------------

cmd_install() {
    # Read the config.toml `[claude]` section first so URL derivation
    # and branch resolution see the configured hostname / branch.
    claude_repo_apply_config "$REPO_ROOT"

    local target_branch
    target_branch=$(claude_repo_resolve_target_branch)
    info "Target branch (resolved): $target_branch"

    if claude_repo_is_our_clone; then
        install_existing_clone "$target_branch"
    elif [[ -e "$CLAUDE_DIR" ]] || [[ -L "$CLAUDE_DIR" ]]; then
        # Anything else that exists at $CLAUDE_DIR (regular dir,
        # symlink, stranger clone, partial state): move aside, fresh
        # clone, overlay. `-L` covers a stale symlink whose target
        # doesn't resolve (which `-e` would miss).
        install_migrate_existing "$target_branch"
    else
        install_fresh_clone "$target_branch"
    fi
    print_repo_state

    # Sync plugins from the clone's settings.json. Non-fatal: a missing
    # `claude` binary / plugins.sh, or a plugins.sh failure, warns but
    # must not abort `make ai` / `make install`.
    sync_claude_plugins_nonfatal --install
}

cmd_update() {
    # Read the config.toml `[claude]` section first so URL derivation
    # and branch resolution see the configured hostname / branch.
    claude_repo_apply_config "$REPO_ROOT"

    if [[ ! -d "$CLAUDE_DIR" ]]; then
        error_exit "$CLAUDE_DIR does not exist. Run 'make claude-install' first."
    fi
    if ! claude_repo_is_our_clone; then
        error_exit "$CLAUDE_DIR is not a clone of $CLAUDE_REPO_URL_HTTPS. Run 'make claude-install' to migrate."
    fi
    local target_branch
    target_branch=$(claude_repo_resolve_target_branch)
    info "Target branch (resolved): $target_branch"
    install_existing_clone "$target_branch"
    print_repo_state

    # Sync plugins from the clone's settings.json. Non-fatal: see
    # `cmd_install`.
    sync_claude_plugins_nonfatal --update
}

cmd_plugins_install() {
    sync_claude_plugins --install
}

cmd_plugins_update() {
    sync_claude_plugins --update
}

cmd_outdated() {
    # Read the config.toml `[claude]` section so `claude_repo_is_our_clone`
    # accepts the configured-hostname URL when checking the existing origin.
    claude_repo_apply_config "$REPO_ROOT"

    if [[ ! -d "$CLAUDE_DIR" ]]; then
        info "$CLAUDE_DIR does not exist. Run 'make claude-install' first."
        return 0
    fi
    if ! claude_repo_is_our_clone; then
        info "$CLAUDE_DIR is not a clone of the global Claude config repo (origin: $(claude_repo_origin_url "$CLAUDE_DIR" || echo "<none>"))."
        info "Run 'make claude-install' to migrate."
        return 0
    fi

    info "Fetching origin (read-only)..."
    git_in_safe_cwd -C "$CLAUDE_DIR" fetch origin --prune

    local current
    current=$(git -C "$CLAUDE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [[ -z "$current" ]]; then
        info "$CLAUDE_DIR is in detached-HEAD state."
        git -C "$CLAUDE_DIR" status -sb
        return 0
    fi

    local upstream
    upstream="origin/$current"

    if ! git -C "$CLAUDE_DIR" rev-parse --verify --quiet "refs/remotes/$upstream" >/dev/null; then
        info "Branch '$current' has no upstream '$upstream'."
        git -C "$CLAUDE_DIR" status -sb
        return 0
    fi

    echo
    info "Commits behind ($current..$upstream):"
    git -C "$CLAUDE_DIR" log --oneline "HEAD..$upstream" || true
    echo
    info "Commits ahead ($upstream..$current):"
    git -C "$CLAUDE_DIR" log --oneline "$upstream..HEAD" || true
    echo
    info "Working tree status:"
    git -C "$CLAUDE_DIR" status -sb || true
}

case "$CMD" in
    install)         cmd_install ;;
    update)          cmd_update ;;
    outdated)        cmd_outdated ;;
    plugins-install) cmd_plugins_install ;;
    plugins-update)  cmd_plugins_update ;;
esac
