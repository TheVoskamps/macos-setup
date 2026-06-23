#!/usr/bin/env bash
# scripts/collision_check.sh — detect (and optionally fix) same-tier
# collisions between Install/ files and their peer Uninstall/ /
# RemoveAndPurge/ slots.
#
# Usage:
#   scripts/collision_check.sh           # report collisions; exit 1 if any
#   scripts/collision_check.sh --fix     # comment out the Install line for
#                                        # each collision, write a .bak,
#                                        # and exit 0 (unless an error)
#
# A "same-tier collision" means: a `brew '<name>'`, `cask '<name>'`, or
# `mas '...', id: NNN` entry appears in BOTH
# `<tier>/Install/NN-Install.suffix` AND
# `<tier>/Uninstall/NN-Uninstall.suffix` (or
# `<tier>/RemoveAndPurge/NN-RemoveAndPurge.suffix`) at the same tier.
#
# Same-tier collisions are bugs: `make update` would just undo the
# install. Cross-tier collisions are intentional ("opt out at a
# more-specific tier") and are NOT reported.
#
# Tiers scanned (each against ITS OWN peer trees):
#   - global:           Install/, Uninstall/, RemoveAndPurge/
#   - profiles/<p>/:    every profile under profiles/
#   - external host tier: the single host dir on local disk (see
#                         host_tier_dir in config_common.sh)
#
# `--fix` (sanitize) edits the Install file in place: comments out the
# offending line with a marker that names the peer file, and writes a
# `.bak` next to the original. The user reviews the diff, commits, and
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

# Read a Brewfile-style file and emit "<lineno>\t<kind>\t<key>\t<raw>"
# for every recognized entry. Skips blank lines and lines whose first
# non-whitespace character is `#` (full-line comments). Trailing
# comments are stripped before matching.
parse_file() {
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

# Walk one tier rooted at $1 (e.g. "$REPO_ROOT",
# "$REPO_ROOT/profiles/dev-core"). For each Install file in that
# tier, scan against the same-tier Uninstall and RemoveAndPurge files.
# Appends collision records to global state via stdout: one TSV line
# per collision, fields:
#   <slot>\t<install_path>\t<install_lineno>\t<install_raw>\t<peer_path>\t<peer_lineno>\t<peer_raw>
scan_tier() {
  local tier_root="$1"
  local install_dir="$tier_root/Install"
  local uninstall_dir="$tier_root/Uninstall"
  local purge_dir="$tier_root/RemoveAndPurge"

  [[ -d "$install_dir" ]] || return 0

  local install_file
  for install_file in "$install_dir"/*-Install.*; do
    [[ -f "$install_file" ]] || continue
    local base
    base="$(basename "$install_file")"
    # NN-Install.suffix -> NN-Uninstall.suffix / NN-RemoveAndPurge.suffix
    local uninstall_base="${base/-Install./-Uninstall.}"
    local purge_base="${base/-Install./-RemoveAndPurge.}"
    local uninstall_file="$uninstall_dir/$uninstall_base"
    local purge_file="$purge_dir/$purge_base"

    # Collect peer keys with their lineno+raw so we can report sources.
    local peer_tmp
    peer_tmp="$(mktemp)"
    if [[ -f "$uninstall_file" ]]; then
      while IFS=$'\t' read -r p_line p_kind p_key p_raw; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$p_kind" "$p_key" "$uninstall_file" "$p_line" "$p_raw" >> "$peer_tmp"
      done < <(parse_file "$uninstall_file")
    fi
    if [[ -f "$purge_file" ]]; then
      while IFS=$'\t' read -r p_line p_kind p_key p_raw; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$p_kind" "$p_key" "$purge_file" "$p_line" "$p_raw" >> "$peer_tmp"
      done < <(parse_file "$purge_file")
    fi

    # If no peer entries, skip this slot quickly.
    if [[ ! -s "$peer_tmp" ]]; then
      rm -f "$peer_tmp"
      continue
    fi

    # Slot label, e.g. "07-browsers" from "07-Install.browsers".
    local nn="${base%%-*}"         # "07"
    local suffix="${base#*-Install.}"  # "browsers"
    local slot="${nn}-${suffix}"

    # For each Install entry, look it up in peer_tmp.
    while IFS=$'\t' read -r i_line i_kind i_key i_raw; do
      # Match on (kind,key). awk -v handles tabs in fields safely.
      local matches
      matches="$(awk -F'\t' -v k="$i_kind" -v v="$i_key" \
        '$1 == k && $2 == v { print $3 "\t" $4 "\t" $5 }' "$peer_tmp")"
      [[ -z "$matches" ]] && continue
      while IFS=$'\t' read -r peer_path peer_line peer_raw; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$slot" "$install_file" "$i_line" "$i_raw" \
          "$peer_path" "$peer_line" "$peer_raw"
      done <<< "$matches"
    done < <(parse_file "$install_file")

    rm -f "$peer_tmp"
  done
}

# --- Tier enumeration ---

tier_roots=()
tier_roots+=("$REPO_ROOT")
if [[ -d "$REPO_ROOT/profiles" ]]; then
  for p in "$REPO_ROOT/profiles"/*/; do
    [[ -d "$p" ]] || continue
    tier_roots+=("${p%/}")
  done
fi
# The host tier lives OUTSIDE the repo now (see host_tier_dir). It is a
# single directory, not one-per-host under computer-specific/. Scan it
# only if it exists.
HOST_DIR="$(host_tier_dir)"
if [[ -d "$HOST_DIR" ]]; then
  tier_roots+=("$HOST_DIR")
fi

# --- Run scans ---

COLLISIONS_TSV="$(mktemp)"
trap 'rm -f "$COLLISIONS_TSV"' EXIT

for tr in "${tier_roots[@]}"; do
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
  while IFS=$'\t' read -r slot install_path install_line install_raw peer_path peer_line peer_raw; do
    install_rel="$(format_rel "$install_path")"
    peer_rel="$(format_rel "$peer_path")"
    echo "WARN: same-tier collision in $slot"
    printf '  %s:%s\t%s\n' "$install_rel" "$install_line" "$install_raw"
    printf '  %s:%s\t%s\n' "$peer_rel"   "$peer_line"   "$peer_raw"
    if [[ "$FIX" -eq 0 ]]; then
      echo "  fix: make sanitize    (will remove the Install line)"
    fi
    echo
  done < "$COLLISIONS_TSV"
  # Count distinct Install lines (file + lineno), not (install, peer)
  # pairs. One Install line that collides with both an Uninstall AND a
  # RemoveAndPurge peer should count as a single collision, since the
  # sanitize pass rewrites it once. See review feedback on PR #89.
  count=$(awk -F'\t' '{print $2 "\t" $3}' "$COLLISIONS_TSV" \
    | sort -u | wc -l | tr -d ' ')
fi

# --- Sanitize (fix) mode ---

if [[ "$FIX" -eq 1 && "$count" -gt 0 ]]; then
  # Process each Install file once. Group lines to comment by file.
  # We rewrite the file by streaming line-by-line and replacing the
  # selected line numbers with a marker + the original line commented.
  today="$(date +%Y-%m-%d)"

  # Build a per-file list of "<lineno>\t<peer_rel>" tuples.
  files_list="$(mktemp)"
  awk -F'\t' '{print $2}' "$COLLISIONS_TSV" | sort -u > "$files_list"

  fixed_files=0
  while IFS= read -r install_path; do
    [[ -n "$install_path" ]] || continue

    # Collect the lines to rewrite for this file.
    targets="$(mktemp)"
    awk -F'\t' -v f="$install_path" '$2 == f { print $3 "\t" $5 }' \
      "$COLLISIONS_TSV" | sort -u > "$targets"

    # Backup once.
    bak="$install_path.bak"
    cp "$install_path" "$bak"

    # Rewrite.
    rewritten="$(mktemp)"
    lineno=0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      lineno=$((lineno + 1))
      # Find a peer for this lineno (first match wins; multiple peers
      # collapse to one comment line and the same commented original).
      peer_match="$(awk -F'\t' -v n="$lineno" '$1 == n { print $2; exit }' "$targets")"
      if [[ -n "$peer_match" ]]; then
        peer_rel="${peer_match#"$REPO_ROOT"/}"
        printf '# sanitized %s: also listed in %s\n' "$today" "$peer_rel" >> "$rewritten"
        printf '# %s\n' "$raw" >> "$rewritten"
      else
        printf '%s\n' "$raw" >> "$rewritten"
      fi
    done < "$install_path"

    mv "$rewritten" "$install_path"
    rm -f "$targets"
    fixed_files=$((fixed_files + 1))
    install_rel="${install_path#"$REPO_ROOT"/}"
    echo "sanitized: $install_rel (backup: $install_rel.bak)"
  done < "$files_list"

  rm -f "$files_list"

  echo
  echo "Sanitized $count collision(s) across $fixed_files file(s)."
  echo "Review the diffs (e.g. \`git diff\`), commit, then remove the .bak files."
  exit 0
fi

# --- Final exit ---

if [[ "$count" -eq 0 ]]; then
  echo "collision-check: no same-tier Install/Uninstall or Install/RemoveAndPurge collisions."
  exit 0
fi

echo "collision-check: $count same-tier collision(s) found."
echo "fix with: make sanitize"
exit 1
