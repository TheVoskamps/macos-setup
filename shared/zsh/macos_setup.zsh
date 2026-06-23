# macos-setup: shared helpers for locating the repo and running make from
# anywhere. Sourced via ~/.zsh-shared by ~/.zshrc.

# Resolve the macos-setup repo root from the ~/.zsh-shared symlink target.
# Delegates to scripts/resolve_repo_root.sh so the resolution logic
# lives in exactly one place. The runner script that LaunchAgents
# invoke (scripts/launchagent_runner.sh) uses the same resolver, so
# `m()` and scheduled jobs always agree on what the repo root is.
_macos_setup_repo() {
    local target
    target="$(readlink ~/.zsh-shared 2>/dev/null)" || return 1
    [[ -n "$target" ]] || return 1
    # `shell_setup.sh` writes ~/.zsh-shared as an absolute symlink,
    # but be defensive: if the target is relative, resolve it against
    # the symlink's parent ($HOME). Matches resolve_repo_root.sh's
    # behavior so both code paths agree on what the target means.
    local abs_target="$target"
    case "$target" in
        /*) ;;
        *)  abs_target="$HOME/$target" ;;
    esac
    local resolver="$(dirname "$abs_target")/../scripts/resolve_repo_root.sh"
    if [[ -x "$resolver" ]]; then
        "$resolver"
    else
        # Older checkouts predate resolve_repo_root.sh. Fall back to
        # the inline calculation so a freshly-pulled-but-not-yet-
        # `make shell`-rerun checkout doesn't break `m`.
        (cd "$(dirname "$abs_target")/.." && pwd)
    fi
}

# Run make in macos-setup from anywhere, preserving the caller's $PWD
# as $START_DIR so Makefile targets can act on it.
m() {
    local repo
    repo="$(_macos_setup_repo)" || {
        echo "m: cannot locate macos-setup repo (~/.zsh-shared not a symlink?)" >&2
        return 1
    }
    local start="$PWD"
    cd "$repo" || return
    START_DIR="$start" make "${@:-help}"
    cd "$start" || return
}

# Wrapper around m() to filter its help output
# e.g. mh "claude" for all claude-related commands
mh () {
    m | grep -- "$@"
}

