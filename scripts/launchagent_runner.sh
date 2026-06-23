#!/bin/bash

# launchagent_runner.sh — single entry point for all macos-setup
# LaunchAgents. Resolves the repo root at run time (via
# `scripts/resolve_repo_root.sh`), `cd`s into it, redirects stdout
# and stderr to `~/Library/Logs/macos-setup/<job>.log`, then `exec`s
# the requested command. Used by `make schedule-daily`,
# `make schedule-weekly`, `make schedule-now`, and
# `make schedule-email-test`.
#
# Why this runner exists (issue #133):
#   The Makefile `schedule-*` targets used to snapshot `$(pwd)` into
#   the generated plist as a literal absolute path in
#   `ProgramArguments[0]`, `WorkingDirectory`, `StandardOutPath`,
#   and `StandardErrorPath`. When the repo was renamed or moved
#   (e.g. `~/Workspaces/Edwin/macos-setup` ->
#   `~/Workspaces/TheVoskamps/macos-setup`) the installed plists
#   silently pointed at a phantom directory. This runner moves all
#   that path resolution to run time so future repo moves don't
#   require re-running `make schedule-*`.
#
# `ProgramArguments[0]` of the generated plist:
#   `$HOME/.zsh-shared/launchagent_runner`
#
#   The plist embeds this literal absolute path (with `$HOME`
#   already substituted to e.g. `/Users/edwin`). It resolves
#   through a two-symlink chain:
#
#     `$HOME/.zsh-shared`             [symlink, managed by
#                                      `scripts/shell_setup.sh`]
#         -> `<repo>/shared/zsh`
#     `$HOME/.zsh-shared/launchagent_runner`   [symlink, committed]
#         -> `../../scripts/launchagent_runner.sh`
#         =  `<repo>/scripts/launchagent_runner.sh`
#
#   Why two symlinks instead of `~/.zsh-shared/../scripts/...`:
#   macOS (and POSIX more generally) resolves `..` *lexically*
#   against the symlink path, not against the symlink target. So
#   `~/.zsh-shared/../scripts/foo` resolves to `~/scripts/foo`,
#   not `<repo>/scripts/foo`. A relative-target symlink committed
#   inside `shared/zsh/` sidesteps that by giving the kernel a
#   path it can resolve fully through the filesystem. See the
#   `LAUNCHAGENT_RUNNER` comment block in the Makefile for the
#   long form.
#
#   Why this location and not, say, `~/.local/bin/macos-setup-...`:
#   the runner needs the same `~/.zsh-shared` symlink to be valid
#   in order to do its own job (resolve the repo root). Tying the
#   runner's reachability to that same symlink means there is one
#   piece of state to maintain, not two.
#
# Usage:
#
#   launchagent_runner.sh <job> -- <command> [args...]
#       Run <command> with its argv directly, log to
#       ~/Library/Logs/macos-setup/<job>.log. The command runs
#       with the repo root as cwd. Used when no email is desired.
#
#   launchagent_runner.sh <job> --mail <recipient> <subject> -- <command> [args...]
#       Pipe the command through `<repo>/scripts/mail_wrapper.sh`,
#       which captures stdout+stderr and sends it as email to
#       <recipient> with subject "<subject>".
#       Note: mail_wrapper itself captures the command's output into
#       an email body, so the log file mostly stays small (just
#       wrapper meta). Errors from mail_wrapper itself still land in
#       the log.
#
# <job> is a short identifier used as the log filename (e.g.
# `daily-update`, `weekly-update`, `now-update`, `email-test`).

set -euo pipefail

if [[ $# -lt 2 ]]; then
    cat >&2 <<'EOF'
Usage:
  launchagent_runner.sh <job> -- <command> [args...]
  launchagent_runner.sh <job> --mail <recipient> <subject> -- <command> [args...]
EOF
    exit 2
fi

JOB="$1"
shift

# Sanitize: jobs are used as filenames; keep them tame.
case "$JOB" in
    *[!A-Za-z0-9._-]*|""|.|..)
        echo "launchagent_runner.sh: invalid <job> '$JOB'" >&2
        exit 2
        ;;
esac

# Resolve the runner's own location so we can find the resolver
# without depending on the working directory. The runner is reached
# via a chain of symlinks (~/.zsh-shared -> <repo>/shared/zsh; then
# <repo>/shared/zsh/launchagent_runner -> ../../scripts/launchagent_runner.sh),
# so BASH_SOURCE[0] is the symlink path through ~/.zsh-shared, not
# the on-disk file's path. We must dereference all symlinks to find
# the directory containing `resolve_repo_root.sh`.
#
# `cd "$(dirname ...)" && pwd -P` only resolves the directory part
# (which is itself a symlink); the file's symlink-target dirname is
# what we actually need. macOS lacks GNU `readlink -f`, so we use
# a small portable loop.
resolve_script_dir() {
    local src="$1"
    while [ -L "$src" ]; do
        local target
        target="$(readlink "$src")"
        case "$target" in
            /*) src="$target" ;;
            *)  src="$(cd "$(dirname "$src")" && pwd -P)/$target" ;;
        esac
    done
    cd "$(dirname "$src")" && pwd -P
}
SCRIPT_DIR="$(resolve_script_dir "${BASH_SOURCE[0]}")"

RESOLVE_REPO_ROOT="$SCRIPT_DIR/resolve_repo_root.sh"
if [[ ! -x "$RESOLVE_REPO_ROOT" ]]; then
    echo "launchagent_runner.sh: cannot find resolve_repo_root.sh at $RESOLVE_REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$("$RESOLVE_REPO_ROOT")"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
    echo "launchagent_runner.sh: resolve_repo_root.sh did not return a usable repo root" >&2
    exit 1
fi

# Log destination: ~/Library/Logs/macos-setup/<job>.log. macOS-native
# (Console.app surfaces these), survives repo moves, and isolates
# LaunchAgent output from the repo's own `logs/` directory.
LOG_DIR="$HOME/Library/Logs/macos-setup"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$JOB.log"

# Redirect stdout+stderr to the log file (appending) for the rest of
# this script and for anything we `exec` after.
exec >>"$LOG_FILE" 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S %z') launchagent_runner.sh job=$JOB ====="
echo "REPO_ROOT=$REPO_ROOT"
echo "PWD-before=$(pwd)"

cd "$REPO_ROOT"
echo "PWD-after=$(pwd)"

# Parse the rest of argv into mode + command.
MAIL_TO=""
MAIL_SUBJECT=""
case "${1:-}" in
    --)
        shift
        ;;
    --mail)
        shift
        if [[ $# -lt 3 ]]; then
            echo "launchagent_runner.sh: --mail requires <recipient> <subject> -- <command...>" >&2
            exit 2
        fi
        MAIL_TO="$1"
        MAIL_SUBJECT="$2"
        shift 2
        if [[ "${1:-}" != "--" ]]; then
            echo "launchagent_runner.sh: expected '--' after --mail <recipient> <subject>" >&2
            exit 2
        fi
        shift
        ;;
    *)
        echo "launchagent_runner.sh: expected '--' or '--mail' after <job>, got '${1:-}'" >&2
        exit 2
        ;;
esac

if [[ $# -lt 1 ]]; then
    echo "launchagent_runner.sh: no command to run after '--'" >&2
    exit 2
fi

echo "Command: $*"
echo "---"

if [[ -n "$MAIL_TO" ]]; then
    # mail_wrapper.sh expects: <recipient> <subject> <command...>
    exec "$REPO_ROOT/scripts/mail_wrapper.sh" "$MAIL_TO" "$MAIL_SUBJECT" "$@"
else
    exec "$@"
fi
