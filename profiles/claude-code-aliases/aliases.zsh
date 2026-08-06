# claude-code-aliases — shell helpers for the Claude Code CLI.
#
# This profile installs NO software. It exists solely to carry aliases
# and functions that wrap the `claude` CLI, so a host that wants the
# claude-code shell conveniences opts in here. The `claude` CLI itself
# is installed by the `claude` and `claude-latest` profiles (mutually
# exclusive per host). A host that lists this profile but no claude
# profile will have `cr` defined but it will fail at call time with
# "command not found: claude" — survivable and self-evident.

# wrapper around claude to get a name and remote control; strict variant
# that requires an existing repo with an 'origin' remote.
cr-repo () {
    local url repo suffix name
    url="$(git remote get-url origin 2>/dev/null)" || {
        echo "cr-repo: not in a git repo or no 'origin' remote" >&2
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

# Like cr-repo, but also works OUTSIDE a git repo (issue #15). Claude Code's
# guardrails hook runs `git` commands that fail when the cwd is not a git
# repo, so `claude` itself misbehaves when launched there. To give it a
# repo to anchor on, when the cwd is not already inside a git repo we
# `git init` a throwaway repo in the current dir, run claude, then remove
# ONLY the .git we created.
#
# When the cwd IS already inside an existing repo (at the repo root OR in
# any subdirectory), there is nothing to create or clean up: we `cd` to
# the repo root, derive the session name from `origin` like `cr-repo`
# does, and run claude there. Detection uses `git rev-parse
# --is-inside-work-tree` (true anywhere inside the tree, unlike a
# root-only `[[ -e .git ]]` check, which would wrongly take the throwaway
# path from a subdirectory and mislabel the session `(local)`). The shell
# is intentionally LEFT at the repo root after this function returns --
# `cr` is a function, so the bare `cd` persists; that is the
# accepted behavior.
#
# The throwaway-repo cleanup is wired through a function-local trap so the
# .git is removed on EVERY return path -- normal exit, an early `return`,
# or the user interrupting `claude` with Ctrl-C. Two zsh subtleties make
# the naive `rm` at the end of the function unsafe, and this
# implementation works around both:
#   1. A function-local EXIT trap fires when the FUNCTION returns (not at
#      shell exit), but by the time its body evaluates the function's
#      `local` variables have already been torn down (they read as empty).
#      So we must NOT reference a local var from inside the trap body.
#      Instead we bake the absolute .git path into the trap string as a
#      literal at trap-set time, while $initdir is still in scope (note
#      the double quotes on `trap`, and the ${(q)...} quoting so a path
#      with spaces survives).
#   2. The trap is set only on the branch that actually ran `git init`,
#      so an existing repo's real .git is never at risk. The baked path
#      is the absolute "$PWD/.git" captured before `claude` runs, so a
#      `cd` by claude cannot redirect the rm.
# INT and TERM are trapped alongside EXIT so that a signal which kills the
# shell outright (rather than just returning from the function) still
# tears down the throwaway .git.
#
# Arguments are split at the FIRST argument starting with `-`: everything
# before it forms the session name suffix, and that argument plus all that
# follow are passed through to `claude` verbatim. So `cr my session
# --model opus` names the session "my session <repo>" and forwards
# `--model opus`. With no leading words the suffix falls back to a
# timestamp, as before.
cr () {
    local url repo suffix name initdir toplevel cfg
    local -a claude_args name_words

    # Point git at a Claude-specific global config (bot identity, etc.) for
    # the duration of this call, unless the caller already set one.
    #
    # `local -x` is what confines it: a zsh `local` is dynamically scoped, so
    # the value is visible to `claude` and to every git command this function
    # runs, and is restored when `cr` returns -- on EVERY return path,
    # including a Ctrl-C out of `claude`. Unlike the `cd` to the repo root,
    # this deliberately does NOT persist in the calling shell; a plain
    # `export` would silently repoint git for the rest of the session.
    # The declaration lives inside the `if` so an outer value is never
    # shadowed by an empty local.
    if [[ -z "${GIT_CONFIG_GLOBAL:-}" ]]; then
        cfg="$HOME/.gitconfig-claude"
        [[ -r "$cfg" ]] && local -x GIT_CONFIG_GLOBAL="$cfg"
    fi

    while (( $# )); do
        if [[ "$1" == -* ]]; then
            # First flag: this and everything after it belongs to claude.
            claude_args=("$@")
            break
        fi
        name_words+=("$1")
        shift
    done

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Inside an existing repo (root or subdir). Move to the repo root
        # and reuse the existing .git -- no throwaway, no cleanup trap.
        toplevel="$(git rev-parse --show-toplevel)"
        echo "cr: detected existing git repo; cd to repo root ${toplevel}" >&2
        cd "$toplevel" || {
            echo "cr: cd to repo root failed" >&2
            return 1
        }
        url="$(git remote get-url origin 2>/dev/null)"
        if [[ -n "$url" ]]; then
            repo="${${url##*/}%.git}"
        else
            repo="(local)"
        fi
    else
        initdir="$PWD"
        git init >/dev/null || {
            echo "cr: git init failed" >&2
            return 1
        }
        # Bake the absolute path in as a literal NOW; see note (1) above.
        trap "rm -rf -- ${(q)initdir}/.git" EXIT INT TERM
        repo="(local)"
    fi

    suffix="${name_words[*]}"
    if [[ -z "$suffix" ]]; then
        suffix="$(date '+%b%d-%H:%M')"
    fi
    name="${suffix} ${repo}"
    claude --name "$name" --remote-control \
        --debug-file "$HOME/.claude/logs/$name" \
        "${claude_args[@]}"
}
# Resolve an installed Claude Code plugin's root from the plugin DB.
# installed_plugins.json stores installPath directly, so this tracks
# plugin updates automatically. The per-plugin value is an array (one
# entry per scope) -- prefer user scope, fall back to first.
claude-plugin-path() {
  local key=$1 db=${CLAUDE_PLUGINS_DB:-$HOME/.claude/plugins/installed_plugins.json}
  [[ -r $db ]] || return 1
  jq -er --arg k "$key" '
    (.plugins[$k] // []) as $e
    | (($e | map(select(.scope == "user"))) + $e)[0].installPath // empty
  ' "$db" 2>/dev/null
}

claude-vm() {
  local root exe
  root=$(claude-plugin-path 'claude-vm@thevoskamps') || {
    print -ru2 -- "claude-vm: plugin claude-vm@thevoskamps is not installed"
    return 127
  }
  exe=$root/bin/claude-vm
  [[ -x $exe ]] || {
    print -ru2 -- "claude-vm: $exe is missing or not executable"
    return 127
  }
  "$exe" "$@"
}
