# claude-code-aliases — shell helpers for the Claude Code CLI.
#
# This profile installs NO software. It exists solely to carry aliases
# and functions that wrap the `claude` CLI, so a host that wants the
# claude-code shell conveniences opts in here. The `claude` CLI itself
# is installed by the `claude` and `claude-latest` profiles (mutually
# exclusive per host). A host that lists this profile but no claude
# profile will have `cr` defined but it will fail at call time with
# "command not found: claude" — survivable and self-evident.

# wrapper around claude to get a name and remote control
cr () {
    local url repo suffix name
    url="$(git remote get-url origin 2>/dev/null)" || {
        echo "cr: not in a git repo or no 'origin' remote" >&2
        return 1
    }
    repo="${${url##*/}%.git}"
    suffix="$*"
    if [[ -z "$suffix" ]]; then
        suffix="$(date '+%b%d-%H:%M')"
    fi
    name="${suffix} ${repo}"
    claude --name "$name" --remote-control
}
