#!/usr/bin/env bash
# scripts/install_filter.sh — pre-process an Install/<NN-Install.suffix> file
# for `brew bundle`, commenting out any line whose package identifier appears
# in an in-scope Uninstall or RemoveAndPurge file of the same numbered slot.
#
# Usage: scripts/install_filter.sh <path-to-Install-file>
#
# Tier rule (driven by the path of the Install file). An Install file is
# filtered against the Uninstall + RemoveAndPurge slots of its OWN tier
# and every HIGHER-priority tier. The tier order, lowest to highest, is:
#
#   default  <  profile[0]  <  profile[1]  <  ...  <  profile[n]  <  host
#
# …where profile[0..n] are the host's profiles in list-file order (see
# computer-specific/<host>/profiles). At each in-scope tier the filter
# scans BOTH the matching Uninstall/<slot> and RemoveAndPurge/<slot>
# file, in that order:
#   - Install/<file>                                 -> filter against
#       default + all profiles + host
#   - profiles/<name>/Install/<file>                 -> filter against
#       <name> + every profile listed AFTER <name> + host
#   - computer-specific/<host>/Install/<file>        -> filter against
#       host only
#
# Matching slots for `Install/NN-Install.suffix` are
# `Uninstall/NN-Uninstall.suffix` and
# `RemoveAndPurge/NN-RemoveAndPurge.suffix`.
#
# Output: prints a temp file path on stdout. The caller is responsible for
# cleaning the temp file up. The filtered file is identical to the input
# except that lines matching the in-scope Uninstall identifiers are
# replaced by:
#
#   # filtered: also listed in <relative/path/to/Uninstall-file>
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
# commented out by the Uninstall/RemoveAndPurge filter is trusted ONLY
# if its own `tap` line still emits — the conservative behavior.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <path-to-Install-file>

Print path to a temp file containing the filtered Install file.
EOF
  exit 64
}

if [[ $# -ne 1 ]]; then
  usage
fi

INSTALL_FILE="$1"

if [[ ! -f "$INSTALL_FILE" ]]; then
  echo "[install-filter] File not found: $INSTALL_FILE" >&2
  exit 2
fi

# --- Determine tier and matching slot basename ---
# We expect the path to end with .../Install/<basename>.
INSTALL_BASENAME="$(basename "$INSTALL_FILE")"
case "$INSTALL_BASENAME" in
  *-Install.*) ;;
  *)
    echo "[install-filter] Not an Install/ entry: $INSTALL_FILE" >&2
    exit 2
    ;;
esac

# Convert "NN-Install.suffix" -> "NN-Uninstall.suffix" and
# "NN-RemoveAndPurge.suffix" so we can scan both peer dirs.
UNINSTALL_SLOT="${INSTALL_BASENAME/-Install./-Uninstall.}"
PURGE_SLOT="${INSTALL_BASENAME/-Install./-RemoveAndPurge.}"

# Resolve the absolute path to a path relative to the repo root, so we can
# classify the tier robustly even if the caller used a relative path.
INSTALL_FILE_ABS="$(cd "$(dirname "$INSTALL_FILE")" && pwd)/$INSTALL_BASENAME"
INSTALL_REL="${INSTALL_FILE_ABS#"$REPO_ROOT"/}"

# The host tier lives OUTSIDE the repo now (see host_tier_dir). Resolve
# its absolute path so an external host-tier Install file is classified
# as the host tier even though its path does not start with
# `computer-specific/`. A relative-path host_tier_dir (e.g. a test
# override) is normalized to absolute too.
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

candidates=()  # ordered list of in-scope Uninstall + RemoveAndPurge file paths

# Helper: append both the Uninstall/ and RemoveAndPurge/ files for a
# given tier root (e.g. "$REPO_ROOT", "$REPO_ROOT/profiles/<p>",
# "$REPO_ROOT/computer-specific/<host>"). Both are conditionally added;
# missing files are skipped later in the loop.
#
# Precedence note: Uninstall is appended FIRST and RemoveAndPurge SECOND
# at every tier. `record()` writes every source it sees and `lookup()`
# returns the LAST match, so when a package is listed in both
# Uninstall/<slot> and RemoveAndPurge/<slot> at the same tier, the
# filter marker comment names the RemoveAndPurge file — the
# operationally more impactful action. Both still cause the line to be
# filtered out of the Install file; only the marker text differs. If
# this precedence ever needs to change, swap the order below or fold
# both sources into the marker in `lookup()`.
add_tier() {
  local tier_root="$1"
  candidates+=("$tier_root/Uninstall/$UNINSTALL_SLOT")
  candidates+=("$tier_root/RemoveAndPurge/$PURGE_SLOT")
}

# Build the in-scope tier list: this tier and every higher-priority
# tier, in least-to-most-specific order (so add_tier records least
# specific first; lookup()'s last-match-wins then names the most
# specific source — see the precedence note above and in lookup()).
#
# The host tier (highest priority) lives at the external $HOST_DIR now,
# not under computer-specific/. An Install file inside $HOST_DIR is the
# host tier; everything else is classified by its repo-relative path.
if [[ "$INSTALL_FILE_ABS" == "$HOST_DIR_ABS/Install/"* ]]; then
  # Host tier: filter against host only (both dirs).
  add_tier "$HOST_DIR"
else
  case "$INSTALL_REL" in
    Install/*)
      # Default tier: scope = default + all profiles (list order) + host.
      add_tier "$REPO_ROOT"
      for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
        add_tier "$REPO_ROOT/profiles/$p"
      done
      add_tier "$HOST_DIR"
      ;;
    profiles/*/Install/*)
      # Profile tier: scope = this profile + every profile listed AFTER
      # it in the host's list + host. A profile not in the host's list
      # (or a zero-profile host) scopes to just that profile + host.
      profile_in_path="${INSTALL_REL#profiles/}"
      profile_in_path="${profile_in_path%%/*}"
      add_tier "$REPO_ROOT/profiles/$profile_in_path"
      seen=0
      for p in ${PROFILES[@]+"${PROFILES[@]}"}; do
        if [[ "$seen" -eq 1 ]]; then
          add_tier "$REPO_ROOT/profiles/$p"
        elif [[ "$p" == "$profile_in_path" ]]; then
          seen=1
        fi
      done
      add_tier "$HOST_DIR"
      ;;
    *)
      echo "[install-filter] Unrecognized Install path: $INSTALL_REL" >&2
      exit 2
      ;;
  esac
fi

# --- Build the identifier sets from in-scope Uninstall + RemoveAndPurge files ---
# We track: brew formulae, casks, and mas IDs separately. For each
# identifier, we also remember which Uninstall/ or RemoveAndPurge/ file
# mentioned it, so we can include that path in the filter marker.

# Use temp files instead of associative arrays for portability/simplicity.
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t install-filter)"
trap 'rm -rf "$TMP_DIR"' EXIT

BREW_MAP="$TMP_DIR/brew_map.tsv"
CASK_MAP="$TMP_DIR/cask_map.tsv"
MAS_MAP="$TMP_DIR/mas_map.tsv"
: > "$BREW_MAP"
: > "$CASK_MAP"
: > "$MAS_MAP"

record() {
  local map="$1" key="$2" path="$3"
  # Append every source for each identifier; `lookup` returns the last
  # match, which is the most-specific tier in our enumeration order.
  printf '%s\t%s\n' "$key" "$path" >> "$map"
}

for un_file in "${candidates[@]}"; do
  [[ -f "$un_file" ]] || continue
  # Marker path: repo-relative for in-repo tiers; for the external host
  # tier, show it host-relative as `<host-dir>/...` so the marker is
  # still readable.
  un_rel="${un_file#"$REPO_ROOT"/}"
  if [[ "$un_rel" == "$un_file" ]] && [[ "$un_file" == "$HOST_DIR"/* ]]; then
    un_rel="<host-dir>/${un_file#"$HOST_DIR"/}"
  fi
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^tap[[:space:]]+ ]]; then
      continue
    fi
    if [[ "$line" =~ ^brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      record "$BREW_MAP" "${BASH_REMATCH[1]}" "$un_rel"
      continue
    fi
    if [[ "$line" =~ ^cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      record "$CASK_MAP" "${BASH_REMATCH[1]}" "$un_rel"
      continue
    fi
    if [[ "$line" =~ ^mas[[:space:]]+[\"\'][^\"\']+[\"\'][[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]]; then
      record "$MAS_MAP" "${BASH_REMATCH[1]}" "$un_rel"
      continue
    fi
    # Malformed entries in Uninstall/ or RemoveAndPurge/ files are an
    # error; we surface them rather than silently skipping, so the smart
    # filter is trustworthy.
    echo "[install-filter] ERROR: $un_rel: malformed or unsupported directive: $line" >&2
    exit 2
  done < "$un_file"
done

lookup() {
  local map="$1" key="$2"
  # Last entry wins. Within a single tier, Uninstall is recorded before
  # RemoveAndPurge (see add_tier), so a package listed in both at the
  # same tier resolves to the RemoveAndPurge file. Across tiers, the
  # most-specific tier wins (host > later profiles > earlier profiles >
  # default) because add_tier() is called in least-to-most-specific
  # order above.
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
      echo "# filtered: also listed in $marker"
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
done < "$INSTALL_FILE"

echo "$OUT"
