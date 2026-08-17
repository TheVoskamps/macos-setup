#!/usr/bin/env bash
# scripts/install_filter.sh — pre-process one tier's `Brewfile` for
# `brew bundle`, commenting out any line whose package identifier appears in
# an in-scope `[profile] uninstall` or `[profile] purge` entry.
#
# Usage: scripts/install_filter.sh <path-to-Brewfile>
#
# Tier rule (driven by the path of the Brewfile). A Brewfile is filtered
# against the removal arrays of its OWN tier and every HIGHER-priority
# tier. The tier order, lowest to highest, is:
#
#   default  <  profile[0]  <  profile[1]  <  ...  <  profile[n]  <  host
#
# …where profile[0..n] are the host's profiles in the order of the
# `profiles` array in the host tier's config.toml. At each in-scope tier
# the filter reads BOTH `[profile] uninstall` and `[profile] purge`, in
# that order:
#   - default/Brewfile            -> filter against
#       default + all profiles + host
#   - profiles/<name>/Brewfile    -> filter against
#       <name> + every profile listed AFTER <name> + host
#   - <host-tier>/Brewfile        -> filter against host only
#
# This is the same scoping the numbered `NN-Install.<slug>` slots had
# before issue #33; only the key changed, from a slot basename to a tier
# root, and only the source changed, from a peer file to a config.toml
# array.
#
# Output: prints a temp file path on stdout. The caller is responsible for
# cleaning the temp file up. The filtered file is identical to the input
# except that lines matching an in-scope removal identifier are replaced by:
#
#   # filtered: also removed by <tier-label> (<kind>)
#   # <original line>
#
# Lines that don't match are passed through verbatim.
#
# SIDE EFFECT (not a pure text transform): for every `tap '<name>'`
# directive that SURVIVES filtering into the emitted output, this script
# runs `brew trust --tap "<name>"` before returning. Homebrew 6.0 made
# `brew trust` required for third-party taps; until a tap is trusted,
# `brew bundle` silently skips its formulae/casks and still exits 0, so
# the failure-tolerant install loop reports success while nothing
# installs (issue #172). Because `install_filter.sh` is the single
# chokepoint every `brew bundle` invocation routes through, trusting the
# emitted taps here guarantees they are trusted before the caller runs
# `brew bundle`. `brew trust` on an already-trusted tap is a no-op, so
# this is idempotent across re-runs. A tap whose only formula/cask was
# commented out by the removal filter is trusted ONLY if its own `tap` line
# still emits — the conservative behavior.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <path-to-Brewfile>

Print path to a temp file containing the filtered Brewfile.
EOF
  exit 64
}

if [[ $# -ne 1 ]]; then
  usage
fi

BREWFILE="$1"

if [[ ! -f "$BREWFILE" ]]; then
  echo "[install-filter] File not found: $BREWFILE" >&2
  exit 2
fi

if [[ "$(basename "$BREWFILE")" != "Brewfile" ]]; then
  echo "[install-filter] Not a tier Brewfile: $BREWFILE" >&2
  exit 2
fi

# The tier root is the Brewfile's parent directory, normalized to absolute
# so the classification below works for a relative caller path.
TIER_ROOT="$(cd "$(dirname "$BREWFILE")" && pwd)"

# The host tier lives OUTSIDE the repo (see host_tier_dir). Normalize a
# relative host_tier_dir (e.g. a test override) to absolute too, so the
# comparison against TIER_ROOT is like-for-like.
HOST_DIR="$(host_tier_dir)"
HOST_DIR_ABS="$HOST_DIR"
if [[ "$HOST_DIR_ABS" != /* ]] && [[ -d "$HOST_DIR_ABS" ]]; then
  HOST_DIR_ABS="$(cd "$HOST_DIR_ABS" && pwd)"
fi

HOSTNAME_LOWER="$(get_hostname)"
# Ordered profile list for this host (lowest priority first).
PROFILES=()
while IFS= read -r _p; do PROFILES+=("$_p"); done < <(get_profiles "$REPO_ROOT")

# Warn (do NOT fail) at install time if a listed profile has no
# matching profiles/<name>/ directory. `make verify` turns the same
# condition into a hard error; install proceeds, just skipping the
# missing tier.
for _p in ${PROFILES[@]+"${PROFILES[@]}"}; do
  if [[ ! -d "$REPO_ROOT/profiles/$_p" ]]; then
    echo "[install-filter] WARNING: host '$HOSTNAME_LOWER' lists unknown profile '$_p' (no profiles/$_p/ directory); skipping that tier" >&2
  fi
done

# --- Build the in-scope tier list ---------------------------------------
# This tier and every higher-priority tier, in least-to-most-specific
# order. `record()` writes every source it sees and `lookup()` returns the
# LAST match, so the marker names the most-specific tier that removes the
# package — and, within one tier, `purge` over `uninstall`, the
# operationally more impactful action. Both filter the line out either way;
# only the marker text differs.
scope=()   # tier roots, least specific first

if [[ "$TIER_ROOT" == "$HOST_DIR_ABS" ]]; then
  scope+=("$HOST_DIR")
elif [[ "$TIER_ROOT" == "$REPO_ROOT/default" ]]; then
  scope+=("$REPO_ROOT/default")
  for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
    scope+=("$REPO_ROOT/profiles/$p")
  done
  scope+=("$HOST_DIR")
elif [[ "$TIER_ROOT" == "$REPO_ROOT/profiles/"* ]]; then
  # Profile tier: scope = this profile + every profile listed AFTER it in
  # the host's list + host. A profile not in the host's list (or a
  # zero-profile host) scopes to just that profile + host.
  profile_in_path="${TIER_ROOT#"$REPO_ROOT"/profiles/}"
  profile_in_path="${profile_in_path%%/*}"
  scope+=("$REPO_ROOT/profiles/$profile_in_path")
  seen=0
  for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
    if [[ "$seen" -eq 1 ]]; then
      scope+=("$REPO_ROOT/profiles/$p")
    elif [[ "$p" == "$profile_in_path" ]]; then
      seen=1
    fi
  done
  scope+=("$HOST_DIR")
else
  echo "[install-filter] Unrecognized Brewfile tier: $BREWFILE" >&2
  exit 2
fi

# --- Build the identifier sets from the in-scope removal arrays ---------
# brew formulae, casks, and mas IDs are tracked separately. For each
# identifier we also remember which tier + which array named it, so the
# filter marker can say where the removal came from.

# Temp files instead of associative arrays, for portability (this must run
# under /bin/bash, i.e. bash 3.2).
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t install-filter)"
trap 'rm -rf "$TMP_DIR"' EXIT

BREW_MAP="$TMP_DIR/brew_map.tsv"
CASK_MAP="$TMP_DIR/cask_map.tsv"
MAS_MAP="$TMP_DIR/mas_map.tsv"
: > "$BREW_MAP"
: > "$CASK_MAP"
: > "$MAS_MAP"

record() {
  local map="$1" key="$2" source="$3"
  # Append every source for each identifier; `lookup` returns the last
  # match, which is the most-specific tier in our enumeration order.
  printf '%s\t%s\n' "$key" "$source" >> "$map"
}

for tier in "${scope[@]}"; do
  label="$(tier_label "$REPO_ROOT" "$tier")"
  for kind in uninstall purge; do
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      parsed="$(parse_removal_entry "$entry")" || {
        echo "[install-filter] ERROR: $label config.toml [profile] $kind: $entry" >&2
        exit 2
      }
      IFS=$'\t' read -r e_kind e_id _e_label <<< "$parsed"
      case "$e_kind" in
        brew) record "$BREW_MAP" "$e_id" "$label ($kind)" ;;
        cask) record "$CASK_MAP" "$e_id" "$label ($kind)" ;;
        mas)  record "$MAS_MAP"  "$e_id" "$label ($kind)" ;;
      esac
    done < <(read_removals "$tier" "$kind")
  done
done

lookup() {
  local map="$1" key="$2"
  # Last entry wins. Within a single tier, uninstall is recorded before
  # purge, so a package in both resolves to purge. Across tiers, the
  # most-specific tier wins (host > later profiles > earlier profiles >
  # core) because the scope list is built least-to-most-specific above.
  awk -F'\t' -v k="$key" '$1 == k { p = $2 } END { if (p) print p }' "$map"
}

# --- Emit the filtered file ---
# OUT is created outside TMP_DIR; lifetime is the caller's responsibility.
OUT="$(mktemp -t install-filter)"

# The brew binary to use for `brew trust`. Overridable via the BREW env
# var so tests can stub it (the same knob the Makefile exposes as
# `BREW=`); defaults to whatever `brew` is on PATH.
BREW="${BREW:-brew}"

while IFS= read -r raw || [[ -n "$raw" ]]; do
  body="${raw%%#*}"
  trimmed="$(echo "$body" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

  marker=""
  if [[ -n "$trimmed" ]]; then
    if [[ "$trimmed" =~ ^brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      src="$(lookup "$BREW_MAP" "${BASH_REMATCH[1]}")"
      [[ -n "$src" ]] && marker="$src"
    elif [[ "$trimmed" =~ ^cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      src="$(lookup "$CASK_MAP" "${BASH_REMATCH[1]}")"
      [[ -n "$src" ]] && marker="$src"
    elif [[ "$trimmed" =~ ^mas[[:space:]]+[\"\'][^\"\']+[\"\'][[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]]; then
      src="$(lookup "$MAS_MAP" "${BASH_REMATCH[1]}")"
      [[ -n "$src" ]] && marker="$src"
    fi
  fi

  if [[ -n "$marker" ]]; then
    {
      echo "# filtered: also removed by $marker"
      echo "# $raw"
    } >> "$OUT"
  else
    # This line is being EMITTED verbatim. If it is a `tap '<name>'`
    # directive, trust the tap now so the caller's `brew bundle` does
    # not silently skip its formulae/casks (issue #172; see the header
    # comment for the full rationale). `brew trust` is idempotent.
    if [[ "$trimmed" =~ ^tap[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      "$BREW" trust --tap "${BASH_REMATCH[1]}" >&2 \
        || echo "[install-filter] WARNING: 'brew trust --tap ${BASH_REMATCH[1]}' failed; brew bundle may skip its packages" >&2
    fi
    printf '%s\n' "$raw" >> "$OUT"
  fi
done < "$BREWFILE"

echo "$OUT"
