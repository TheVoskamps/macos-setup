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

# Like cr, but also works OUTSIDE a git repo (issue #15). Claude Code's
# guardrails hook runs `git` commands that fail when the cwd is not a git
# repo, so `claude` itself misbehaves when launched there. To give it a
# repo to anchor on, we `git init` a throwaway repo in the current dir
# when one is absent, run claude, then remove ONLY the .git we created.
#
# The cleanup is wired through a function-local EXIT trap so the
# throwaway .git is removed on EVERY return path -- normal exit, an early
# `return`, or the user interrupting `claude` with Ctrl-C. Two zsh
# subtleties make the naive `rm` at the end of the function unsafe, and
# this implementation works around both:
#   1. An EXIT trap set inside a zsh function runs AFTER the function
#      returns, in the CALLER's environment, where the function's `local`
#      variables are already gone (empty). So we must NOT reference a
#      local var from inside the trap body. Instead we bake the absolute
#      .git path into the trap string as a literal at trap-set time, when
#      $initdir is still in scope (note the double quotes on `trap`).
#   2. The trap is set only on the branch that actually ran `git init`,
#      so an existing repo's real .git is never at risk. The baked path
#      is the absolute "$PWD/.git" captured before `claude` runs, so a
#      `cd` by claude cannot redirect the rm.
cr-anywhere () {
    local url repo suffix name initdir
    if [[ -e .git ]]; then
        url="$(git remote get-url origin 2>/dev/null)"
        if [[ -n "$url" ]]; then
            repo="${${url##*/}%.git}"
        else
            repo="(local)"
        fi
    else
        initdir="$PWD"
        git init >/dev/null || {
            echo "cr-anywhere: git init failed" >&2
            return 1
        }
        # Bake the absolute path in as a literal NOW; see note (1) above.
        trap "rm -rf -- ${(q)initdir}/.git" EXIT
        repo="(local)"
    fi
    suffix="$*"
    if [[ -z "$suffix" ]]; then
        suffix="$(date '+%b%d-%H:%M')"
    fi
    name="${suffix} ${repo}"
    claude --name "$name" --remote-control
}
