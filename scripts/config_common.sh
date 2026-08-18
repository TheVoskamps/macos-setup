#!/usr/bin/env bash

# Shared configuration resolution library
#
# Tier model (lowest to highest priority):
#
#   default  <  profile[0]  <  profile[1]  <  ...  <  profile[n]  <  host
#
# A host opts into N ordered profiles by listing them in the `profiles`
# array of the EXTERNAL host tier's `config.toml` (lowest priority first;
# the last-listed profile sits just under the host tier). A host with no
# `profiles` array collapses to the two-tier `default < host` model.
#
# The host tier lives OUTSIDE the repo, at the path returned by
# `host_tier_dir` (default `${XDG_CONFIG_HOME:-$HOME/.config}/macos-setup`,
# overridable via `MACOS_SETUP_HOST_DIR`). The in-repo tree keeps only
# `default/` and `profiles/`. See `host_tier_dir`.
#
# Config files resolve in one of two ways, declared centrally below:
#
#   - SINGLE-WINNER: the highest-priority tier that has the file wins;
#     everything below is ignored. See resolve_file / resolve_dir.
#   - AGGREGATE: every tier that has the file contributes, concatenated
#     in `default -> profiles -> host` order. See resolve_aggregate.

# --- Central file-kind table -------------------------------------------
#
# Relative paths that AGGREGATE (concatenate / union across all tiers).
# Everything not listed here is single-winner. Each tier's `Brewfile` and
# its `[profile]` section of config.toml also aggregate, but they are
# driven by the Makefile / install_filter.sh tier walk rather than by these
# resolver functions, so they are documented here but not enumerated as
# resolver paths. See "Tier enumeration" below.
AGGREGATE_FILES=(
    "aliases.zsh"
)

# Single-winner files (highest tier wins). Listed for documentation and
# for callers that want to assert a path's kind; resolve_file /
# resolve_dir apply this behavior to ANY path not in AGGREGATE_FILES.
#
# The scalar config knobs that used to live in `config/mailer`,
# `config/claude`, and `cron/mailto` are now consolidated into a single
# `config.toml` per tier (issue #156). The `[mailer]`, `[claude]`, and
# `[cron]` sections of `config.toml` are single-winner; the `profiles`
# array is the one aggregate key (see resolve_config_value and
# get_profiles below); and the `[profile]` section is PER-TIER — never
# resolved across tiers at all (see read_post_install / read_removals).
# `config.toml` itself is single-winner per section, so it is not in
# AGGREGATE_FILES.
SINGLE_WINNER_FILES=(
    ".vscode/settings.json"
    ".hammerspoon/init.lua"
    ".hammerspoon/monitors.json"
    ".hammerspoon/workspaces.json"
    ".hammerspoon/modules"
    "config.toml"
)

# Return 0 if the given relative path is an aggregate file.
is_aggregate_file() {
    local candidate="$1"
    local f
    for f in "${AGGREGATE_FILES[@]}"; do
        [[ "$f" == "$candidate" ]] && return 0
    done
    return 1
}

# Get normalized hostname (lowercase, strip .local)
get_hostname() {
    local hostname
    hostname=$(scutil --get LocalHostName 2>/dev/null || echo "")
    echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//'
}

# --- External host tier -------------------------------------------------
#
# The per-host tier no longer lives in the repo (it mixed personal,
# per-machine config into tracked files). It now lives on local disk,
# OUTSIDE the repo, carrying config.toml (the consolidated profiles
# array + [claude]/[mailer]/[cron] sections), aliases.zsh,
# .hammerspoon/*, .vscode/settings.json, Brewfile, and .cdk.json.
# Backup/sync of this directory is the user's responsibility.
#
# The base path is routed through ONE function so it is overridable
# (tests point it at a temp dir) and easy to change later. The override
# is the `MACOS_SETUP_HOST_DIR` environment variable; when unset the
# canonical location is `${XDG_CONFIG_HOME:-$HOME/.config}/macos-setup`.
#
# Note: the in-repo tiers (default + profiles) are unchanged. Only the
# host tier's LOCATION moved; the resolution ORDER is still
# default < profiles < host.
host_tier_dir() {
    if [[ -n "${MACOS_SETUP_HOST_DIR:-}" ]]; then
        echo "$MACOS_SETUP_HOST_DIR"
        return 0
    fi
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/macos-setup"
}

# --- config.toml read helpers ------------------------------------------
#
# The scalar config knobs are consolidated into a single per-tier
# `config.toml` (issue #156). TOML is queried with `dasel`, a guaranteed
# bootstrap primitive (installed by bootstrap.sh alongside Homebrew /
# 1Password / mas), so these helpers depend on it unconditionally — no
# graceful-degradation branch. If `dasel` is genuinely missing the read
# fails loudly rather than silently returning wrong values.
#
# dasel v3 read contract (now actively ASSERTED at runtime by
# require_dasel_v3 below, not merely assumed; the contract was originally
# pinned against dasel 3.11.0, the version `bootstrap.sh`'s
# `install_dasel` pulls via Homebrew):
#
#   - Input comes from STDIN; the format is given with `-i toml`. The v2
#     flags `-f/-r/-w` do NOT exist in v3 and error with exit 80.
#   - A property is selected with the `get("name")` function, chained for
#     nested access: `get("claude").get("branch")`. Bare dotted selectors
#     (`claude.branch`) break when a segment collides with a grammar
#     keyword (e.g. `branch`), so we always use `get()`.
#   - Scalar string output is wrapped in single quotes (`'value'`), or
#     double quotes when the value itself contains a single quote
#     (`"it's fine"`). Numbers come back bare. dequote_scalar strips one
#     matching outer quote pair.
#   - A missing key exits non-zero (1) with "map key not found" on
#     STDERR and nothing on STDOUT. A BROKEN invocation (bad flag,
#     missing binary) exits with a different non-zero code (80, 127, …)
#     and may print usage to STDOUT — that is the silent-corruption path
#     the v2 form fell into, so the helpers below treat any non-zero exit
#     that is NOT a clean missing-key as a hard, loud failure.
#
# The v2 -> v3 jump was a TOTAL breaking change (flags removed, query and
# array contract rewritten, even `--version` replaced by a `version`
# subcommand). A future v3 -> v4 jump is just as likely to break every
# read silently. require_dasel_v3 (below) therefore asserts the major
# version is EXACTLY 3 before the first read in a process, rejecting both
# v2 and v4+. dasel is a hard runtime dependency of essentially every
# `make` target (the Makefile -> list_profiles.sh -> get_profiles ->
# read_toml_array -> dasel chain runs at parse time), so the guard sits
# at the universal chokepoint: the read helpers.

DASEL="${DASEL:-dasel}"

# Memoization guard for require_dasel_v3 so the version assertion runs at
# most once per process even though read_toml_value / read_toml_array are
# called many times. Unset until the first successful check passes.
__DASEL_V3_OK="${__DASEL_V3_OK:-}"

# Assert that the dasel on PATH (via the $DASEL indirection) reports major
# version EXACTLY 3, and abort loudly otherwise. v3's `dasel version`
# subcommand prints a bare version like `3.11.0` and exits 0; v2 used
# `dasel --version` ("dasel version 2.x.y") and v4+ may change the surface
# again — so we run the v3 `version` subcommand, take the first
# dot-separated component of stdout, and require it to equal 3. A missing
# binary, a non-zero exit, or unparseable output is treated as a hard
# failure (NOT "assume ok"): a silent wrong-version read is exactly the
# corruption mode this guard exists to prevent.
#
# Memoized via __DASEL_V3_OK so it runs at most once per process. Written
# to behave identically under bash and zsh: no `local status` (a
# read-only special in zsh), no word-splitting assumptions.
#
# Hard-abort behavior: the read helpers call this from inside `$(...)`
# command substitutions, where a plain `exit 1` only kills the subshell
# and leaves the consuming process (e.g. `make` -> list_profiles.sh)
# running with an empty result — a SILENT failure, exactly what this
# guard exists to prevent. So on the reject paths we both `kill -s TERM`
# the top-level process (`$$` is the parent PID even inside a command
# substitution, in both bash and zsh) AND `exit 1`. The kill aborts the
# whole consumer when called from a subshell; the exit covers the
# direct-call case and acts as a fallback if the signal is trapped.
__dasel_die() {
    echo "Error: $1" >&2
    kill -s TERM "$$" 2>/dev/null
    exit 1
}

require_dasel_v3() {
    [[ -n "$__DASEL_V3_OK" ]] && return 0

    local raw rc major
    raw="$("$DASEL" version 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        __dasel_die "dasel version check failed (\`$DASEL version\` exited $rc). dasel v3 is a hard dependency of config.toml reads; install it via bootstrap.sh (install_dasel)."
    fi

    # First whitespace-delimited token, then its first dot-separated
    # component. v3 prints a bare `3.11.0`; tolerate any leading token in
    # case a future build prefixes it.
    raw="${raw%%[[:space:]]*}"
    major="${raw%%.*}"

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        __dasel_die "could not parse a dasel version from \`$DASEL version\` output: [$raw]. dasel v3 is required for config.toml reads (see bootstrap.sh install_dasel)."
    fi
    if [[ "$major" != "3" ]]; then
        __dasel_die "dasel major version $major found ($raw), but exactly v3 is required for config.toml reads. The v2->v3 and any v3->v4 contract changes break reads silently. Install dasel v3 via bootstrap.sh (install_dasel)."
    fi

    __DASEL_V3_OK=1
    return 0
}

# Print the path to a tier's config.toml, given a base directory.
# `base` is a tier root (e.g. the host tier dir, a profile dir, or the
# default dir). Returns the path even if it does not exist; callers test
# for existence.
config_toml_path() {
    local base="$1"
    echo "$base/config.toml"
}

# Build a dasel v3 selector from a dotted path. Each segment is wrapped
# in get("...") so reserved-word segments (e.g. `branch`) resolve as map
# lookups rather than grammar keywords. "claude.branch" -> get("claude").get("branch")
# A single-segment selector ("profiles") -> get("profiles").
#
# The split is done by hand (not via IFS word-splitting) so it behaves
# identically under bash and zsh — zsh does not word-split unquoted
# expansions by default, which would otherwise leave the whole dotted
# string as one segment.
dasel_selector() {
    local dotted="$1"
    local out="" seg rest="$dotted"
    while [[ -n "$rest" ]]; do
        seg="${rest%%.*}"          # first segment, up to the first dot
        if [[ "$rest" == *.* ]]; then
            rest="${rest#*.}"      # strip leading "seg."
        else
            rest=""                # last segment
        fi
        if [[ -n "$out" ]]; then
            out="${out}.get(\"${seg}\")"
        else
            out="get(\"${seg}\")"
        fi
    done
    printf '%s' "$out"
}

# Strip one matching outer single- OR double-quote pair from a dasel
# scalar value. Leaves bare values (numbers, already-unquoted) untouched.
dequote_scalar() {
    local s="$1"
    if [[ ${#s} -ge 2 && "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
        s="${s:1:${#s}-2}"
    elif [[ ${#s} -ge 2 && "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
        s="${s:1:${#s}-2}"
    fi
    printf '%s' "$s"
}

# Read a single scalar from a config.toml file via dasel (v3 contract).
# Args: toml_file, selector (e.g. "mailer.smtp_host", "claude.branch").
# Emits the value (unquoted) on stdout, or nothing when the file is
# absent or the selector path does not exist. A missing optional key is a
# normal state (return empty, exit 0). Any OTHER dasel failure (broken
# invocation, missing binary) is a hard error: it prints a diagnostic to
# stderr and returns non-zero, so a corrupt read can never masquerade as
# a value (issue #156 review — the v2 form returned usage-on-stdout as
# the "value").
read_toml_value() {
    local toml_file="$1"
    local selector="$2"
    [[ -f "$toml_file" ]] || return 0

    # Any dasel read asserts the v3 contract exactly once per process.
    require_dasel_v3

    # NB: avoid the variable name `status` — it is a read-only special
    # variable in zsh, and config_common.sh may be sourced under zsh.
    local sel out err rc
    sel="$(dasel_selector "$selector")"
    err="$(mktemp)"
    out="$("$DASEL" -i toml "$sel" <"$toml_file" 2>"$err")"
    rc=$?

    if [[ $rc -eq 0 ]]; then
        rm -f "$err"
        dequote_scalar "$out"
        return 0
    fi

    # A clean "missing key" is the only acceptable non-zero outcome.
    if grep -q 'map key not found' "$err"; then
        rm -f "$err"
        return 0
    fi

    # Anything else (bad flag, missing binary, parse error) is a real
    # failure. Surface it loudly rather than emitting whatever landed on
    # stdout as if it were the value.
    echo "Error: dasel read failed for selector '$selector' in $toml_file" >&2
    cat "$err" >&2
    rm -f "$err"
    return 1
}

# Resolve a SINGLE-WINNER config.toml section scalar across tiers.
# Walks the precedence stack (host > reverse(profiles) > default) and
# returns the first tier whose config.toml defines a non-empty value for
# the selector. This is the config.toml analogue of resolve_file for the
# `[mailer]`, `[claude]`, and `[cron]` sections.
# Args: repo_root, selector (e.g. "claude.branch", "mailer.smtp_host").
resolve_config_value() {
    local repo_root="$1"
    local selector="$2"

    # Tier: external host tier (highest priority).
    local v
    v="$(read_toml_value "$(config_toml_path "$(host_tier_dir)")" "$selector")"
    if [[ -n "$v" ]]; then echo "$v"; return 0; fi

    # Tiers: profiles, highest priority first (reverse of list order).
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles "$repo_root")
    local i
    for (( i = ${#profiles[@]} - 1; i >= 0; i-- )); do
        v="$(read_toml_value \
            "$(config_toml_path "$repo_root/profiles/${profiles[$i]}")" "$selector")"
        if [[ -n "$v" ]]; then echo "$v"; return 0; fi
    done

    # Tier: default (lowest priority).
    v="$(read_toml_value \
        "$(config_toml_path "$repo_root/default")" "$selector")"
    if [[ -n "$v" ]]; then echo "$v"; return 0; fi

    echo ""
}

# --- Profile-name validation -------------------------------------------
#
# A profile name is BOTH a directory component (`profiles/<name>/`) and a
# word in the Makefile's `TIERS` list, which is built as
# `$(addprefix profiles/,$(PROFILES))`. GNU make splits a variable on
# whitespace, so a name carrying a space (or a tab) becomes TWO tier
# words there while `tier_roots()` below — a newline-safe
# `while IFS= read -r` walk — resolves it as one. The two walks would
# then disagree: `make install` would silently skip two nonexistent
# tiers and `verify.sh` would check the real one.
#
# Of the two ways to close that gap — teach the Makefile a newline-safe
# walk, or refuse the names that break it — we take the second. Make has
# no list type whose elements can contain whitespace, so the first is not
# expressible; the second is one predicate at the single read chokepoint.
#
# The permitted charset is deliberately narrower than "no whitespace":
# `$`, `#`, `%`, `:`, `\` and friends are each special somewhere in make,
# in a shell word, or in a filesystem path, and no real profile needs
# them. Every profile in `profiles/` matches this pattern today.
PROFILE_NAME_RE='^[A-Za-z0-9._-]+$'

# Return 0 when the given profile name is usable in every walk.
profile_name_is_valid() {
    [[ "$1" =~ $PROFILE_NAME_RE ]]
}

# Read the host's profile list from config.toml WITHOUT validating it.
#
# The profile list is the one AGGREGATE key in config.toml: it cannot be
# resolved *through* profiles (it defines the stack), so it is read from
# `default` and `host` only. The host tier's `profiles` array is the
# base; if `default`'s config.toml carries a `profiles` array it is
# PREPENDED (default-first, host-second priority order — same direction
# as aliases.zsh aggregation). When a default entry and a host entry name
# the same profile the LAST occurrence wins (dedup-keeping-last), so a
# host re-listing a default profile moves it later in the order.
#
# Callers want either the usable names (get_profiles) or the rejected
# ones (get_invalid_profiles); both partition this one read, so the
# prepend/dedup rules live here once.
#
# `repo_root` locates the default tier's config.toml; the host tier is
# the external host_tier_dir.
read_raw_profiles() {
    local repo_root="$1"

    local default_toml host_toml
    default_toml="$(config_toml_path "$repo_root/default")"
    host_toml="$(config_toml_path "$(host_tier_dir)")"

    # Read each tier's profiles array, one entry per line.
    local default_list host_list
    default_list="$(read_toml_array "$default_toml" "profiles")"
    host_list="$(read_toml_array "$host_toml" "profiles")"

    # Concatenate default-first, host-second, then dedup keeping the last
    # occurrence of each name.
    local combined
    combined="$(printf '%s\n%s\n' "$default_list" "$host_list")"
    dedup_keep_last <<< "$combined"
}

# Get the ordered list of profiles for the current host.
#
# Emits one profile name per line, in final priority order (lowest
# first). Emits nothing when neither tier carries a profiles array.
#
# Names that fail profile_name_is_valid are DROPPED, with a warning on
# stderr naming each one. Dropping (rather than aborting) is what keeps
# the Makefile's parse-time `$(shell list_profiles.sh)` expansion honest:
# an abort there would fire before any target's prerequisite could report
# it, the same trap `list_profiles.sh` already guards against for a
# missing dasel. `make verify` turns the same rejection into a hard
# error via get_invalid_profiles, which is where a user goes to have
# their config checked.
get_profiles() {
    local repo_root="$1"

    local p rejected=()
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if profile_name_is_valid "$p"; then
            printf '%s\n' "$p"
        else
            rejected+=("$p")
        fi
    done < <(read_raw_profiles "$repo_root")

    if [[ ${#rejected[@]} -gt 0 ]]; then
        echo "Warning: ignoring unusable profile name(s) in the 'profiles' array of $(host_tier_dir)/config.toml (allowed: letters, digits, '.', '_', '-'):" >&2
        for p in "${rejected[@]}"; do
            echo "Warning:   - [$p]" >&2
        done
    fi
}

# The complement of get_profiles: the names it dropped, one per line.
# `make verify` uses this to fail loudly on a config that would
# otherwise only warn.
get_invalid_profiles() {
    local repo_root="$1"
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        profile_name_is_valid "$p" || printf '%s\n' "$p"
    done < <(read_raw_profiles "$repo_root")
}

# Read a TOML array as newline-separated entries via dasel (v3 contract).
# Args: toml_file, selector (e.g. "profiles").
# Emits one element per line, in array order. Emits nothing when the file
# is absent or the array is missing/empty.
#
# dasel v3 has no plain one-element-per-line writer, and `.all()` errors
# on a string array. We instead read the array length with
# `len(get(...))` and pull each element by index with `.get(N)`, so the
# read uses only the stable v3 query surface and no JSON parser. Each
# element is dequoted. A missing array yields zero elements: the length
# read fails (non-zero, "map key not found"), leaving `count` empty, and
# the `^[0-9]+$` guard then returns before iterating. The guard also
# rejects any non-numeric garbage on stdout (e.g. usage text from a
# broken invocation), so a corrupt read degrades to an empty list rather
# than emitting junk profile names.
read_toml_array() {
    local toml_file="$1"
    local selector="$2"
    [[ -f "$toml_file" ]] || return 0

    # Any dasel read asserts the v3 contract exactly once per process.
    require_dasel_v3

    local sel count i el
    sel="$(dasel_selector "$selector")"

    # Length: a missing key exits non-zero -> treat as empty array.
    count="$("$DASEL" -i toml "len($sel)" <"$toml_file" 2>/dev/null)" || count=""
    [[ "$count" =~ ^[0-9]+$ ]] || return 0

    for (( i = 0; i < count; i++ )); do
        el="$("$DASEL" -i toml "${sel}.get($i)" <"$toml_file" 2>/dev/null)" || continue
        dequote_scalar "$el"
        printf '\n'
    done
}

# --- Tier enumeration ---------------------------------------------------
#
# A TIER ROOT is the directory that holds one tier's `Brewfile`,
# `config.toml`, `aliases.zsh`, and friends. There are exactly three
# shapes, and they are the same three the resolvers above walk:
#
#   $repo_root/default            the CORE tier (lowest priority)
#   $repo_root/profiles/<name>    one per profile the host opted into,
#                                 in the host's list order
#   $(host_tier_dir)              the external host tier (highest)
#
# The numbered `Install/NN-Install.<slug>` convention these replaced is
# gone: a tier contributes ONE unnumbered Brewfile, and the profile IS the
# category (issue #33).

# Emit every tier root for this host, one per line, in APPLY order
# (lowest priority first: core -> profiles in list order -> host).
# Args: repo_root
tier_roots() {
    local repo_root="$1"
    echo "$repo_root/default"
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && echo "$repo_root/profiles/$p"
    done < <(get_profiles "$repo_root")
    host_tier_dir
}

# Human-readable label for a tier root, for banners and error messages.
#
# The tier root is normalized to an absolute path FIRST. Callers legitimately
# pass relative roots — the Makefile's tier list is `default profiles/<name>
# … $(HOST_DIR)`, mixing both — and comparing a relative `default` against
# an absolute `$repo_root/default` matches nothing, which silently mislabels
# every in-repo tier as the host tier.
#
# A tier that matches none of the three shapes falls back to its own path
# rather than a guessed label, so a caller passing something unexpected sees
# what it passed.
# Args: repo_root, tier_root
tier_label() {
    local repo_root="$1" tier_root="$2"
    local abs="$tier_root"
    if [[ "$abs" != /* ]] && [[ -d "$abs" ]]; then
        abs="$(cd "$abs" && pwd)"
    fi

    local host_abs
    host_abs="$(host_tier_dir)"
    if [[ "$host_abs" != /* ]] && [[ -d "$host_abs" ]]; then
        host_abs="$(cd "$host_abs" && pwd)"
    fi

    case "$abs" in
        "$repo_root/default")    echo "core" ;;
        "$repo_root/profiles/"*) echo "profile ${abs#"$repo_root"/profiles/}" ;;
        "$host_abs")             echo "host" ;;
        *)                       echo "$tier_root" ;;
    esac
}

# --- [profile] section reads --------------------------------------------
#
# `[profile]` is the one config.toml section that is NOT resolved across
# tiers. [claude]/[mailer]/[cron] answer "what is the value for this host",
# so the highest tier with a value wins (resolve_config_value). [profile]
# answers "what does THIS tier contribute", so every tier's section applies
# on its own, in tier order. Reading it is therefore a plain per-file read,
# never a precedence walk.

# Emit this tier's post-install commands, one per line, in declared order.
# Each is a repo-root-relative script path plus optional arguments.
# Args: tier_root
read_post_install() {
    read_toml_array "$(config_toml_path "$1")" "profile.post_install"
}

# Emit this tier's removal entries for one kind, one per line, in declared
# order. Args: tier_root, kind (uninstall|purge).
read_removals() {
    local tier_root="$1" kind="$2"
    case "$kind" in
        uninstall|purge) ;;
        *) echo "read_removals: unknown kind '$kind' (want uninstall|purge)" >&2; return 2 ;;
    esac
    read_toml_array "$(config_toml_path "$tier_root")" "profile.$kind"
}

# Parse one removal entry into "<kind>\t<identifier>\t<label>".
#
#   brew:<formula>    -> brew  <formula>  <formula>
#   cask:<token>      -> cask  <token>    <token>
#   mas:<id>          -> mas   <id>       <id>
#   mas:<id>:<Name>   -> mas   <id>       <Name>
#
# `identifier` is what the package is addressed by (and what the install
# filter matches a Brewfile line against); `label` is only ever used in log
# lines. Returns 2 and prints a diagnostic on a malformed entry — a silently
# ignored removal is exactly the failure this parse exists to prevent.
# Args: entry
parse_removal_entry() {
    local entry="$1"
    local kind="${entry%%:*}"
    local rest="${entry#*:}"

    if [[ "$entry" != *:* || -z "$rest" ]]; then
        echo "malformed removal entry (want '<kind>:<identifier>'): $entry" >&2
        return 2
    fi

    case "$kind" in
        brew|cask)
            if [[ "$rest" == *:* ]]; then
                echo "malformed removal entry ('$kind' takes no label): $entry" >&2
                return 2
            fi
            printf '%s\t%s\t%s\n' "$kind" "$rest" "$rest"
            ;;
        mas)
            local id="${rest%%:*}" label
            if [[ "$rest" == *:* ]]; then label="${rest#*:}"; else label="$id"; fi
            if [[ ! "$id" =~ ^[0-9]+$ ]]; then
                echo "malformed removal entry (mas id must be numeric): $entry" >&2
                return 2
            fi
            printf '%s\t%s\t%s\n' "mas" "$id" "$label"
            ;;
        *)
            echo "malformed removal entry (unknown kind '$kind', want brew|cask|mas): $entry" >&2
            return 2
            ;;
    esac
}

# Read newline-separated names on stdin and emit them deduplicated,
# keeping the LAST occurrence of each name (so a later tier re-listing a
# name moves it later in the order). Blank lines are dropped. Order of
# the surviving entries is the order of their last occurrences.
dedup_keep_last() {
    awk 'NF { line[NR]=$0; last[$0]=NR }
         END { for (i=1;i<=NR;i++) if (last[line[i]]==i) print line[i] }'
}

# Resolve a SINGLE-WINNER file: highest-priority tier wins.
# Precedence stack (highest first): host > reverse(profiles) > default.
# Args: repo_root, relative_path (e.g., ".hammerspoon/init.lua")
resolve_file() {
    local repo_root="$1"
    local relative_path="$2"

    # Tier: external host tier (highest priority).
    local computer_path
    computer_path="$(host_tier_dir)/$relative_path"
    if [[ -f "$computer_path" ]]; then
        echo "$computer_path"
        return 0
    fi

    # Tiers: profiles, highest priority first (reverse of list order).
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles "$repo_root")
    local i
    for (( i = ${#profiles[@]} - 1; i >= 0; i-- )); do
        local profile_path="$repo_root/profiles/${profiles[$i]}/$relative_path"
        if [[ -f "$profile_path" ]]; then
            echo "$profile_path"
            return 0
        fi
    done

    # Tier: default (lowest priority).
    local default_path="$repo_root/default/$relative_path"
    if [[ -f "$default_path" ]]; then
        echo "$default_path"
        return 0
    fi

    echo ""
}

# Resolve a SINGLE-WINNER directory: highest-priority tier wins.
# Same precedence as resolve_file. Args: repo_root, relative_path.
resolve_dir() {
    local repo_root="$1"
    local relative_path="$2"

    # Tier: external host tier (highest priority).
    local computer_path
    computer_path="$(host_tier_dir)/$relative_path"
    if [[ -d "$computer_path" ]]; then
        echo "$computer_path"
        return 0
    fi

    # Tiers: profiles, highest priority first (reverse of list order).
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles "$repo_root")
    local i
    for (( i = ${#profiles[@]} - 1; i >= 0; i-- )); do
        local profile_path="$repo_root/profiles/${profiles[$i]}/$relative_path"
        if [[ -d "$profile_path" ]]; then
            echo "$profile_path"
            return 0
        fi
    done

    # Tier: default (lowest priority).
    local default_path="$repo_root/default/$relative_path"
    if [[ -d "$default_path" ]]; then
        echo "$default_path"
        return 0
    fi

    echo ""
}

# Resolve an AGGREGATE file: emit the existing tier paths for a relative
# file, one per line, in concatenation order:
#
#   default -> profile[0] -> profile[1] -> ... -> profile[n] -> host
#
# Only tiers that actually contain the file are emitted. The caller
# concatenates them (e.g. aliases.zsh, where later tiers override
# earlier ones via zsh "last definition wins"). Emits nothing if no
# tier has the file.
# Args: repo_root, relative_path (e.g., "aliases.zsh")
resolve_aggregate() {
    local repo_root="$1"
    local relative_path="$2"

    # Tier: default (lowest priority, base of the aggregate).
    local default_path="$repo_root/default/$relative_path"
    [[ -f "$default_path" ]] && echo "$default_path"

    # Tiers: profiles in list order (low to high).
    local p
    while IFS= read -r p; do
        local profile_path="$repo_root/profiles/$p/$relative_path"
        [[ -f "$profile_path" ]] && echo "$profile_path"
    done < <(get_profiles "$repo_root")

    # Tier: external host tier (highest priority).
    local computer_path
    computer_path="$(host_tier_dir)/$relative_path"
    [[ -f "$computer_path" ]] && echo "$computer_path"
}

# Backup existing file or directory with timestamp
backup_if_exists() {
    local target="$1"

    if [[ ! -e "$target" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${target}.backup.${timestamp}"

    echo "Backing up existing $(basename "$target") to $(basename "$backup_path")..."
    mv "$target" "$backup_path"
}

# Prepare target path for new content (remove symlink or backup regular file/directory)
prepare_target() {
    local target="$1"

    if [[ -L "$target" ]]; then
        echo "Removing existing symlink: $(basename "$target")..."
        rm "$target"
    elif [[ -e "$target" ]]; then
        backup_if_exists "$target"
    fi
}

# Get repository root
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || {
        echo "Error: Not in a git repository" >&2
        exit 1
    }
}

# Check if path is a symlink and return its target
get_symlink_target() {
    local path="$1"

    if [[ -L "$path" ]]; then
        realpath "$path"
    else
        echo ""
    fi
}

# Seed the external host tier from the in-repo template, but ONLY if the
# external dir does not already exist. This is the entire seeding
# behavior:
#
#   - external host dir absent -> create it and copy the template tree in
#   - external host dir present -> no-op (never overwrite the user's edits)
#
# The template tree lives at `computer-specific/_template/` and is the
# single source of the seed. It carries config.toml (the consolidated
# profiles array + [claude]/[mailer]/[cron] sections), aliases.zsh,
# .vscode/settings.json, and .cdk.json with safe, commented-out
# defaults.
#
# There is NO migration from any existing tracked `computer-specific/
# <hostname>/` directory: the owner moves those over by hand if/when
# wanted. Re-running after the dir exists is idempotent (a no-op).
#
# Args: repo_root
seed_host_tier_if_absent() {
    local repo_root="$1"
    local dest
    dest="$(host_tier_dir)"

    if [[ -e "$dest" ]]; then
        info "Host tier already present at $dest — leaving it untouched."
        return 0
    fi

    local template_dir="$repo_root/computer-specific/_template"
    info "Seeding external host tier at $dest from template..."
    mkdir -p "$dest"

    # Copy the _template/ tree CONTENTS (the `/.` form) into dest.
    if [[ -d "$template_dir" ]]; then
        cp -R "$template_dir/." "$dest/"
    fi

    success "Host tier seeded at $dest. Edit it to taste; it is yours to back up."
}

# Print error message and exit
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Print success message
success() {
    echo "✓ $1"
}

# Print info message
info() {
    echo "→ $1"
}
