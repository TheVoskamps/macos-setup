#!/usr/bin/env bash
# scripts/collision_check.sh — detect (and optionally fix) same-tier
# collisions between a tier's `Brewfile` and that same tier's
# `[profile] uninstall` / `[profile] purge` arrays in config.toml.
#
# Usage:
#   scripts/collision_check.sh           # report collisions; exit 1 if any
#   scripts/collision_check.sh --fix     # comment out the Brewfile line for
#                                        # each collision, write a .bak,
#                                        # and exit 0 (unless an error)
#
# A "same-tier collision" means: a `brew '<name>'`, `cask '<name>'`, or
# `mas '...', id: NNN` entry appears in BOTH `<tier>/Brewfile` AND
# `<tier>/config.toml`'s `[profile] uninstall` or `[profile] purge` array.
#
# Same-tier collisions are bugs: the install and the removal in one tier
# just undo each other. Cross-tier collisions are intentional ("opt out at a
# more-specific tier") and are NOT reported.
#
# Tiers scanned (each against ITS OWN config.toml):
#   - core:               default/
#   - profiles/<p>/:      EVERY profile under profiles/, opted into or not
#   - external host tier: the single host dir on local disk (see
#                         host_tier_dir in config_common.sh)
#
# `--fix` (sanitize) edits the Brewfile in place: comments out the
# offending line with a marker naming the array it collides with, and writes
# a `.bak` next to the original. The user reviews the diff, commits, and
# removes the `.bak`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=config_common.sh
source "$SCRIPT_DIR/config_common.sh"

FIX=0
case "${1:-}" in
  --fix)   FIX=1 ;;
  "")      ;;
  *)
    echo "Usage: $(basename "$0") [--fix]" >&2
    exit 64
    ;;
esac

# --- Helpers ---

# Extract identifier (key) from a Brewfile-style line. Echoes
# "<kind>\t<key>" where kind is brew|cask|mas, or nothing if the line
# isn't one of those directives.
extract_key() {
  local line="$1"
  # Strip leading/trailing whitespace; do NOT strip comments here —
  # the caller passes only non-comment content.
  # Bash regex has no back-references, so we test the single- and
  # double-quoted forms separately to require matching quote types.
  if [[ "$line" =~ ^brew[[:space:]]+\'([^\']+)\' ]] \
    || [[ "$line" =~ ^brew[[:space:]]+\"([^\"]+)\" ]]; then
    printf 'brew\t%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ ^cask[[:space:]]+\'([^\']+)\' ]] \
    || [[ "$line" =~ ^cask[[:space:]]+\"([^\"]+)\" ]]; then
    printf 'cask\t%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ ^mas[[:space:]]+\'[^\']+\'[[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]] \
    || [[ "$line" =~ ^mas[[:space:]]+\"[^\"]+\"[[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]]; then
    printf 'mas\t%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Read a Brewfile and emit "<lineno>\t<kind>\t<key>\t<raw>" for every
# recognized entry. Skips blank lines and lines whose first non-whitespace
# character is `#` (full-line comments). Trailing comments are stripped
# before matching.
parse_brewfile() {
  local f="$1"
  local lineno=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    # Strip trailing comment.
    local body="${raw%%#*}"
    # Trim.
    body="$(printf '%s' "$body" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$body" ]] && continue
    local kv
    kv="$(extract_key "$body")" || continue
    printf '%s\t%s\t%s\n' "$lineno" "$kv" "$raw"
  done < "$f"
}

# Scan one tier rooted at $1. Emits one TSV line per collision:
#   <tier_label>\t<brewfile>\t<lineno>\t<raw>\t<array_name>\t<entry>
scan_tier() {
  local tier_root="$1"
  local brewfile="$tier_root/Brewfile"
  [[ -f "$brewfile" ]] || return 0

  local label
  label="$(tier_label "$REPO_ROOT" "$tier_root")"

  # Collect this tier's removal entries as "<kind>\t<id>\t<array>".
  local peer_tmp
  peer_tmp="$(mktemp)"
  local kind_name entry parsed e_kind e_id
  for kind_name in uninstall purge; do
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      parsed="$(parse_removal_entry "$entry")" || {
        echo "[collision-check] ERROR: $label config.toml [profile] $kind_name: $entry" >&2
        rm -f "$peer_tmp"
        exit 2
      }
      IFS=$'\t' read -r e_kind e_id _ <<< "$parsed"
      printf '%s\t%s\t%s\t%s\n' "$e_kind" "$e_id" "$kind_name" "$entry" >> "$peer_tmp"
    done < <(read_removals "$tier_root" "$kind_name")
  done

  if [[ ! -s "$peer_tmp" ]]; then
    rm -f "$peer_tmp"
    return 0
  fi

  while IFS=$'\t' read -r i_line i_kind i_key i_raw; do
    local matches
    matches="$(awk -F'\t' -v k="$i_kind" -v v="$i_key" \
      '$1 == k && $2 == v { print $3 "\t" $4 }' "$peer_tmp")"
    [[ -z "$matches" ]] && continue
    while IFS=$'\t' read -r arr_name arr_entry; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$brewfile" "$i_line" "$i_raw" "$arr_name" "$arr_entry"
    done <<< "$matches"
  done < <(parse_brewfile "$brewfile")

  rm -f "$peer_tmp"
}

# --- Tier enumeration ---
#
# NOT tier_roots(): that walks only the profiles THIS host opted into, and
# a same-tier collision inside a profile nobody has opted into yet is still
# a bug in the repo. Scan every profile directory on disk.

tier_roots_all=()
tier_roots_all+=("$REPO_ROOT/default")
if [[ -d "$REPO_ROOT/profiles" ]]; then
  for p in "$REPO_ROOT/profiles"/*/; do
    [[ -d "$p" ]] || continue
    tier_roots_all+=("${p%/}")
  done
fi
HOST_DIR="$(host_tier_dir)"
if [[ -d "$HOST_DIR" ]]; then
  tier_roots_all+=("$HOST_DIR")
fi

# --- Run scans ---

COLLISIONS_TSV="$(mktemp)"
trap 'rm -f "$COLLISIONS_TSV"' EXIT

for tr in "${tier_roots_all[@]}"; do
  scan_tier "$tr" >> "$COLLISIONS_TSV"
done

# --- Report ---

format_rel() {
  local p="$1"
  local rel="${p#"$REPO_ROOT"/}"
  # External host-tier paths don't sit under $REPO_ROOT; show them
  # host-relative as `<host-dir>/...` so the report stays readable.
  if [[ "$rel" == "$p" ]] && [[ "$p" == "$HOST_DIR"/* ]]; then
    rel="<host-dir>/${p#"$HOST_DIR"/}"
  fi
  printf '%s' "$rel"
}

count=0
if [[ -s "$COLLISIONS_TSV" ]]; then
  while IFS=$'\t' read -r label brewfile lineno raw arr_name entry; do
    echo "WARN: same-tier collision in $label"
    printf '  %s:%s\t%s\n' "$(format_rel "$brewfile")" "$lineno" "$raw"
    printf '  config.toml [profile] %s\t"%s"\n' "$arr_name" "$entry"
    if [[ "$FIX" -eq 0 ]]; then
      echo "  fix: make sanitize    (will comment out the Brewfile line)"
    fi
    echo
  done < "$COLLISIONS_TSV"
  # Count distinct Brewfile lines (file + lineno), not (install, removal)
  # pairs. One Brewfile line that collides with both the `uninstall` AND the
  # `purge` array counts as a single collision, since the sanitize pass
  # rewrites it once.
  count=$(awk -F'\t' '{print $2 "\t" $3}' "$COLLISIONS_TSV" \
    | sort -u | wc -l | tr -d ' ')
fi

# --- Sanitize (fix) mode ---

if [[ "$FIX" -eq 1 && "$count" -gt 0 ]]; then
  # Process each Brewfile once. Group lines to comment by file. We rewrite
  # the file by streaming line-by-line and replacing the selected line
  # numbers with a marker + the original line commented.
  today="$(date +%Y-%m-%d)"

  files_list="$(mktemp)"
  awk -F'\t' '{print $2}' "$COLLISIONS_TSV" | sort -u > "$files_list"

  fixed_files=0
  while IFS= read -r brewfile; do
    [[ -n "$brewfile" ]] || continue

    # Collect the lines to rewrite for this file, as "<lineno>\t<array>".
    targets="$(mktemp)"
    awk -F'\t' -v f="$brewfile" '$2 == f { print $3 "\t" $5 }' \
      "$COLLISIONS_TSV" | sort -u > "$targets"

    # Backup once.
    bak="$brewfile.bak"
    cp "$brewfile" "$bak"

    # Rewrite.
    rewritten="$(mktemp)"
    lineno=0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      lineno=$((lineno + 1))
      # Find an array for this lineno (first match wins; a line in both
      # arrays collapses to one comment and the same commented original).
      arr_match="$(awk -F'\t' -v n="$lineno" '$1 == n { print $2; exit }' "$targets")"
      if [[ -n "$arr_match" ]]; then
        printf '# sanitized %s: also in this tier'"'"'s [profile] %s array\n' "$today" "$arr_match" >> "$rewritten"
        printf '# %s\n' "$raw" >> "$rewritten"
      else
        printf '%s\n' "$raw" >> "$rewritten"
      fi
    done < "$brewfile"

    mv "$rewritten" "$brewfile"
    rm -f "$targets"
    fixed_files=$((fixed_files + 1))
    rel="$(format_rel "$brewfile")"
    echo "sanitized: $rel (backup: $rel.bak)"
  done < "$files_list"

  rm -f "$files_list"

  echo
  echo "Sanitized $count collision(s) across $fixed_files file(s)."
  echo "Review the diffs (e.g. \`git diff\`), commit, then remove the .bak files."
  exit 0
fi

# --- Final exit ---

if [[ "$count" -eq 0 ]]; then
  echo "collision-check: no same-tier Brewfile/uninstall or Brewfile/purge collisions."
  exit 0
fi

echo "collision-check: $count same-tier collision(s) found."
echo "fix with: make sanitize"
exit 1
