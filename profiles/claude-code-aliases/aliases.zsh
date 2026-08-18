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

# Update every marketplace and enabled plugin declared in the global
# Claude settings.json. A plugin entry in .enabledPlugins is either a
# boolean or an object with an `enabled` key; the type guard on the
# object index matters because jq's `or` does not short-circuit the
# right operand's evaluation errors -- indexing a boolean with
# .enabled aborts the whole filter (claude-config#44).
#
# No-op chatter is dropped from each command's stdout with the same
# grep -Ev filter as ~/.claude/plugins.sh, whose QUIET_PATTERNS is the
# upstream source of these patterns -- keep the list textually
# identical to it. grep exits 1 when it emits nothing, which is
# exactly what an up-to-date item looks like, so the command's own
# status is read from zsh's pipestatus (1-indexed) before anything
# else can overwrite it; `| grep ... || true` would clobber it. stderr
# is not piped, so genuine error text still reaches the terminal.
update_claude_plugins() {
  local settings="${1:-$HOME/.claude/settings.json}"
  local i st
  local -a marketplaces plugins
  local quiet_patterns='Refreshing marketplace cache|Successfully updated marketplace|Checking for updates for plugin|is already at the latest version'

  marketplaces=("${(@f)$(jq -r '.extraKnownMarketplaces // {} | keys[]' "$settings")}")
  for i in "${marketplaces[@]}"; do
    [[ -n "$i" ]] || continue
    claude plugin marketplace update "$i" | grep -Ev "$quiet_patterns"
    st=$pipestatus[1]
    (( st == 0 )) || echo "update_claude_plugins: marketplace update failed: $i (exit $st)" >&2
  done

  plugins=("${(@f)$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true or ((.value | type) == "object" and .value.enabled == true)) | .key' "$settings")}")
  for i in "${plugins[@]}"; do
    [[ -n "$i" ]] || continue
    claude plugin update "$i" | grep -Ev "$quiet_patterns"
    st=$pipestatus[1]
    (( st == 0 )) || echo "update_claude_plugins: plugin update failed: $i (exit $st)" >&2
  done
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

# Multiple Claude Code Max accounts on one machine (issue #49).
#
# Skills, plugins, settings and session history stay shared in ~/.claude;
# only the pieces that carry account identity get swapped:
#   - the OAuth token in the macOS Keychain, service "Claude Code-credentials"
#   - the .oauthAccount block in ~/.claude.json
# Per-account backups live in the Keychain item
# "Claude Code-credentials-<account>" and the sidecar file
# ~/.claude.json.<account> (created 0400 -- only ever read back).
#
# Two kinds of profile: the BUILT-IN DEFAULT (used when --account is
# omitted, stored under the suffix "default") and NAMED profiles
# (explicit --account NAME). The name "default" can never be typed --
# `--account default` is always rejected -- so the implicit profile and
# an explicitly-named one can never be confused. Account names must
# match ^[A-Za-z0-9._@-]+$ (the repo's PROFILE_NAME_RE charset plus @,
# so an account email works verbatim as the name).
#
# CONCURRENCY LIMITATION (documented, not guarded): there is one live
# identity at a time. Switching while another Claude session is running
# repoints the Keychain item and ~/.claude.json underneath it. No
# locking is implemented -- quit running Claude sessions before
# switching. See docs/SHELL.md.

save_claude_auth () {
    local account="default" pw oauth explicit=0 force=0

    while (( $# )); do
        if [[ "$1" == "--account" ]]; then
            if (( $# < 2 )); then
                echo "save_claude_auth: --account requires a value" >&2
                return 1
            fi
            account="$2"
            explicit=1
            shift 2
        elif [[ "$1" == "--force" ]]; then
            force=1
            shift
        else
            echo "save_claude_auth: unknown argument: $1" >&2
            return 1
        fi
    done

    if (( explicit )); then
        if [[ "$account" == "default" ]]; then
            echo "save_claude_auth: 'default' cannot be specified explicitly -- omit --account to use the built-in default" >&2
            return 1
        fi
        if [[ ! "$account" =~ '^[A-Za-z0-9._@-]+$' ]]; then
            echo "save_claude_auth: invalid account name '${account}' -- allowed characters are A-Z a-z 0-9 . _ @ -" >&2
            return 1
        fi
    fi

    if [[ -f ~/.claude.json."${account}" ]] && (( ! force )); then
        if [[ "$account" == "default" ]]; then
            echo "save_claude_auth: the built-in default already has a saved account -- pass --force to overwrite it" >&2
        else
            echo "save_claude_auth: '${account}' already has a saved account -- pass --force to overwrite it" >&2
        fi
        return 1
    fi

    pw=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w) || {
        echo "save_claude_auth: not currently logged in" >&2
        return 1
    }

    oauth=$(jq '.oauthAccount' ~/.claude.json 2>/dev/null)
    if [[ -z "$oauth" || "$oauth" == "null" ]]; then
        echo "save_claude_auth: no oauthAccount in ~/.claude.json -- not currently logged in" >&2
        unset pw
        return 1
    fi

    # The Keychain backup is written before the sidecar, and each write
    # is checked: a failed write reports the state it actually left
    # behind and returns non-zero, never the "saved" message.
    if ! security add-generic-password -U -s "Claude Code-credentials-${account}" -a "$USER" -w "$pw" >/dev/null; then
        unset pw
        echo "save_claude_auth: writing the Keychain backup for '${account}' FAILED -- nothing was saved (no Keychain backup, no sidecar)" >&2
        return 1
    fi
    unset pw

    # The sidecar is created 0400 (read-only for the owner: it is only
    # ever read back by load_claude_auth), so a --force overwrite must
    # remove the old one before writing. `command rm` bypasses the
    # `rm -i` safety alias from default/aliases.zsh.
    command rm -f ~/.claude.json."${account}"
    if ! jq -n --argjson oauth "$oauth" '{oauthAccount: $oauth}' > ~/.claude.json."${account}"; then
        echo "save_claude_auth: writing the sidecar ~/.claude.json.${account} FAILED -- the Keychain backup for '${account}' was written but the sidecar is missing or incomplete, so load_claude_auth will not accept this profile; re-run save_claude_auth with --force" >&2
        return 1
    fi
    chmod 0400 ~/.claude.json."${account}"
    echo "save_claude_auth: saved '${account}'" >&2
}

load_claude_auth () {
    local account="default" pw oauth tmp live sidecar explicit=0 force=0 matched=0

    while (( $# )); do
        if [[ "$1" == "--account" ]]; then
            if (( $# < 2 )); then
                echo "load_claude_auth: --account requires a value" >&2
                return 1
            fi
            account="$2"
            explicit=1
            shift 2
        elif [[ "$1" == "--force" ]]; then
            force=1
            shift
        else
            echo "load_claude_auth: unknown argument: $1" >&2
            return 1
        fi
    done

    if (( explicit )); then
        if [[ "$account" == "default" ]]; then
            echo "load_claude_auth: 'default' cannot be specified explicitly -- omit --account to use the built-in default" >&2
            return 1
        fi
        if [[ ! "$account" =~ '^[A-Za-z0-9._@-]+$' ]]; then
            echo "load_claude_auth: invalid account name '${account}' -- allowed characters are A-Z a-z 0-9 . _ @ -" >&2
            return 1
        fi
    fi

    [[ -f ~/.claude.json."${account}" ]] || {
        if [[ "$account" == "default" ]]; then
            echo "load_claude_auth: no built-in default saved yet -- run save_claude_auth (no --account) while logged into it" >&2
        else
            echo "load_claude_auth: no saved account '${account}' -- run save_claude_auth --account ${account} first" >&2
        fi
        return 1
    }

    # Refuse to clobber an unsaved identity: loading overwrites the live
    # Keychain item and ~/.claude.json, and if the identity that was
    # live was never saved it is gone (that account must be logged into
    # again). Compare the live oauthAccount against every sidecar on
    # .emailAddress and .accountUuid; abort unless one matches or
    # --force is passed.
    if (( ! force )); then
        live=$(jq -c '.oauthAccount // empty' ~/.claude.json 2>/dev/null)
        if [[ -n "$live" && "$live" != "null" ]]; then
            for sidecar in ~/.claude.json.*(N); do
                if jq -e --argjson live "$live" \
                    '.oauthAccount as $s
                     | $s.emailAddress == $live.emailAddress
                       and $s.accountUuid == $live.accountUuid' \
                    "$sidecar" >/dev/null 2>&1; then
                    matched=1
                    break
                fi
            done
            if (( ! matched )); then
                echo "load_claude_auth: the current login was never saved and would be lost -- run save_claude_auth first, or pass --force to discard it" >&2
                return 1
            fi
        fi
    fi

    # Validate every source the swap depends on BEFORE changing
    # anything, so a bad input means "refused, nothing changed" rather
    # than a half-applied switch that leaves the Keychain and
    # ~/.claude.json naming different accounts. There is deliberately
    # no unwind past the first write: a write that fails anyway
    # reports the state it actually left behind and returns non-zero.
    pw=$(security find-generic-password -s "Claude Code-credentials-${account}" -a "$USER" -w 2>/dev/null) || {
        echo "load_claude_auth: no Keychain entry for '${account}'" >&2
        return 1
    }

    oauth=$(jq '.oauthAccount' ~/.claude.json."${account}" 2>/dev/null)
    if [[ -z "$oauth" || "$oauth" == "null" ]]; then
        echo "load_claude_auth: sidecar ~/.claude.json.${account} is unreadable or carries no oauthAccount -- nothing changed" >&2
        unset pw
        return 1
    fi

    # Build the rewritten ~/.claude.json first, while everything is
    # still untouched. The temp file lives next to its destination
    # (inside $HOME, so the test sandbox contains it and the mv below
    # stays on one filesystem); its name does not match the
    # ~/.claude.json.* sidecar pattern, so a leftover can never be
    # mistaken for a saved profile.
    tmp=$(mktemp ~/.claude.json-new.XXXXXX) || {
        echo "load_claude_auth: cannot create a temp file under \$HOME -- nothing changed" >&2
        unset pw
        return 1
    }
    if ! jq --argjson oauth "$oauth" '.oauthAccount = $oauth' ~/.claude.json > "$tmp"; then
        echo "load_claude_auth: cannot rewrite ~/.claude.json (is it valid JSON?) -- nothing changed" >&2
        command rm -f "$tmp"
        unset pw
        return 1
    fi

    if ! security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$pw" >/dev/null; then
        echo "load_claude_auth: writing the live Keychain item FAILED -- the Keychain and ~/.claude.json are both unchanged (still the previous account)" >&2
        command rm -f "$tmp"
        unset pw
        return 1
    fi
    unset pw

    # `command mv -f` bypasses the `mv -i` safety alias that
    # default/aliases.zsh defines for every host, which would prompt.
    if ! command mv -f "$tmp" ~/.claude.json; then
        echo "load_claude_auth: the Keychain now holds '${account}' but rewriting ~/.claude.json FAILED -- the two halves name different accounts; re-run load_claude_auth for '${account}'" >&2
        command rm -f "$tmp"
        return 1
    fi
    echo "load_claude_auth: switched to '${account}'" >&2
}
