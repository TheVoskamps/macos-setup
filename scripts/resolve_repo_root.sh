#!/bin/sh

# resolve_repo_root.sh — print the absolute macos-setup repo root.
#
# Single source of truth for runtime repo-root resolution. Reads
# `~/.zsh-shared`, which `scripts/shell_setup.sh` symlinks to
# `<repo>/shared/zsh`, and walks two levels up to the repo root.
#
# Callers:
#   - `shared/zsh/macos_setup.zsh` (the `m()` macro)
#   - `scripts/launchagent_runner.sh` (the LaunchAgent runner that
#     stands in for the old absolute-path-snapshotted plist values)
#
# Why the symlink, not `$(pwd)`: a LaunchAgent plist generated when
# the repo lived at `~/Workspaces/Edwin/macos-setup` still points
# at that phantom path after the repo is renamed/moved (e.g. to
# `~/Workspaces/TheVoskamps/macos-setup`). Resolving at run time via
# the `~/.zsh-shared` symlink avoids that whole class of bug — when
# `make shell` (or `make install`) reruns `scripts/shell_setup.sh`,
# the symlink is updated to point at the current repo, and every
# downstream runtime resolution follows.
#
# Behavior:
#   - On success: prints the absolute repo root on stdout, exits 0.
#   - On failure (missing or non-symlink `~/.zsh-shared`, or target
#     does not exist): prints an explanatory message to stderr, exits
#     non-zero. Callers should fail loudly rather than silently
#     fall back to `$(pwd)` — a silent fallback recreates the
#     exact bug this script was introduced to prevent.
#
# POSIX shell on purpose: this script is invoked from plist-driven
# contexts (LaunchAgents) where `bash` and `zsh` are both available
# but `/bin/sh` is the most stable choice. It's also sourced
# indirectly by the `m()` zsh function, which forks a child to run
# it — no shell-feature dependency leaks back into the caller.

set -eu

SYMLINK="${HOME}/.zsh-shared"

if [ ! -L "$SYMLINK" ]; then
    echo "resolve_repo_root.sh: ~/.zsh-shared is not a symlink" >&2
    echo "  (expected: ~/.zsh-shared -> <repo>/shared/zsh)" >&2
    echo "  fix: run 'make shell' from your macos-setup checkout" >&2
    exit 1
fi

TARGET="$(readlink "$SYMLINK")"
if [ -z "$TARGET" ]; then
    echo "resolve_repo_root.sh: readlink ~/.zsh-shared returned empty" >&2
    exit 1
fi

# `readlink` on macOS returns whatever was stored, which is usually
# an absolute path (shell_setup.sh writes it as `ln -s <abs> <dst>`).
# Be defensive: resolve relative targets against the symlink's parent.
case "$TARGET" in
    /*)
        ABS_TARGET="$TARGET"
        ;;
    *)
        ABS_TARGET="$(dirname "$SYMLINK")/$TARGET"
        ;;
esac

# Repo root is two levels up from `shared/zsh`. Use `cd && pwd -P`
# to get a fully resolved path (no symlinks, no `..` segments).
REPO_ROOT="$(cd "$ABS_TARGET/../.." 2>/dev/null && pwd -P)" || {
    echo "resolve_repo_root.sh: cannot cd into '$ABS_TARGET/../..'" >&2
    echo "  (the symlink target may have been deleted)" >&2
    exit 1
}

if [ ! -d "$REPO_ROOT" ]; then
    echo "resolve_repo_root.sh: resolved repo root '$REPO_ROOT' does not exist" >&2
    exit 1
fi

printf '%s\n' "$REPO_ROOT"
