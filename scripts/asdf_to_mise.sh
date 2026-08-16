#!/usr/bin/env bash
# asdf_to_mise.sh — one-shot, idempotent, purely ADDITIVE migration from
# asdf + direnv to mise, for one repository per invocation.
#
# `make asdf-to-mise` is a deliberate exception to this repo's
# implementation-neutral target naming: it names both endpoints on purpose
# because it is a migration verb, and it is deleted once every repo and
# host is over.
#
# What it does:
#   - ensures the global mise config exists and sets `env_file = ".env"`
#   - converts the calling repo's `.tool-versions` into a `mise.toml`
#   - writes a sentinel-guarded `.gitignore` block pinning `mise.toml` as
#     the ONE tracked config form
#   - warns about every asdf/direnv leftover it finds. For the two per-repo
#     leftovers (`.envrc`, `.tool-versions`) it reports three INDEPENDENT
#     conditions, in any combination, each with its own remedy: present on
#     disk, matched by an ignore rule, and tracked in git. The third is not
#     a variation on the second — .gitignore has no effect on a path already
#     in the index, so only `git rm` clears it.
#
# What it deliberately does NOT do: delete anything, move anything, untrack
# anything, or commit anything. `~/.asdf/`, `~/.tool-versions`,
# `~/.config/direnv/lib/use_asdf.sh`, the repo's `.envrc`, and the repo's
# `.tool-versions` are all left exactly where they are. The user removes
# them once they are satisfied with the conversion.
#
# It operates on the CALLING directory (START_DIR), not on macos-setup —
# the same mechanism the outgoing `direnv-enable` / `direnv-disable`
# targets used.

set -euo pipefail

MISE_LOG_TAG="ASDF-TO-MISE"
export MISE_LOG_TAG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=mise_common.sh
. "$SCRIPT_DIR/mise_common.sh"

log()  { mise_log "$@"; }
warn() { mise_warn "$@"; }
err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }

TARGET_DIR="${START_DIR:-$PWD}"

GITIGNORE_SENTINEL_BEGIN="# --- mise (managed by macos-setup \`make asdf-to-mise\`) ---"
GITIGNORE_SENTINEL_END="# --- end mise ---"

# --- Global steps -----------------------------------------------------

global_steps() {
  echo
  log "== Global =="
  ensure_global_mise_config
  ensure_mise_env_file_setting

  echo
  log "Global asdf/direnv leftovers (NOT removed — delete them yourself when ready):"

  local found=0
  local d
  for d in "${ASDF_DATA_DIR:-}" "$HOME/.asdf" "$HOME/.local/share/asdf"; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    found=1
    printf '  - %s (%s) — asdf plugins, installs, downloads and shims\n' \
      "$d" "$(du -sh "$d" 2>/dev/null | awk '{print $1}' || echo 'size unknown')"
  done

  if [ -f "$HOME/.config/direnv/lib/use_asdf.sh" ]; then
    found=1
    printf '  - %s — a copy of the outgoing use_asdf helper; its only function shells out to the now-absent `asdf` binary\n' \
      "$HOME/.config/direnv/lib/use_asdf.sh"
  fi

  if [ -f "$HOME/.tool-versions" ]; then
    found=1
    printf '  - %s — superseded by %s once the import above ran\n' \
      "$HOME/.tool-versions" "$(mise_global_config_path)"
  fi

  [ "$found" -eq 0 ] && printf '  (none found)\n'
  return 0
}

# --- Per-repo steps ---------------------------------------------------

# Abort unless TARGET_DIR is the ROOT of a git repository. This step
# writes .gitignore, so being invoked from a subdirectory is almost
# certainly a mistake.
require_repo_root() {
  local top
  if ! top="$(cd "$TARGET_DIR" && git rev-parse --show-toplevel 2>/dev/null)"; then
    err "$TARGET_DIR is not inside a git repository. Run this from the root of the repo you want to convert."
    exit 1
  fi
  # Compare resolved paths so a symlinked path does not false-negative.
  local resolved
  resolved="$(cd "$TARGET_DIR" && pwd -P)"
  top="$(cd "$top" && pwd -P)"
  if [ "$resolved" != "$top" ]; then
    err "$TARGET_DIR is not the root of its git repository (root is $top). Re-run from the repository root."
    exit 1
  fi
}

# asdf reads `<tool> <v1> <v2>` as a fallback list; `mise generate config`
# turns it into a TOML array, which mise then resolves as TWO tools to
# install — silently replacing the pinned build with the newest match and
# adding a spurious second version. Refuse to convert such a file.
#
# Detection: any uncommented, non-blank line with three or more
# whitespace-separated fields.
reject_multi_version_lines() {
  local tv="$1"
  local bad
  # Quote the ORIGINAL line (comments included) so the user can find it,
  # but decide on the comment-stripped field count.
  bad="$(awk '
    { original = $0; sub(/#.*/, "") }
    NF >= 3 { print original }
  ' "$tv")"

  if [ -n "$bad" ]; then
    err "$tv carries multi-version line(s), which convert to a broken TOML array:"
    printf '%s\n' "$bad" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '    %s\n' "$line" >&2
    done
    err "asdf reads '<tool> <v1> <v2>' as a fallback list; mise reads the converted array as two tools to install."
    err "Rewrite each as a single version token (e.g. 'java temurin 26.0.1+8' -> 'java temurin-26.0.1+8'), then re-run."
    err "No mise.toml was written."
    exit 1
  fi
}

generate_repo_config() {
  local tv="$TARGET_DIR/.tool-versions"
  local out="$TARGET_DIR/mise.toml"

  if [ ! -f "$tv" ]; then
    log "No .tool-versions in $TARGET_DIR — skipping mise.toml generation."
    return 0
  fi

  reject_multi_version_lines "$tv"

  if [ -f "$out" ]; then
    log "$out already exists — left untouched (not clobbered)."
    return 0
  fi

  log "Generating $out from $tv"
  ( cd "$TARGET_DIR" && "$MISE" generate config --tool-versions .tool-versions -y )
}

# Write the .gitignore block that pins `mise.toml` as the ONE tracked
# config form. mise loads EVERY config form it finds per directory, merged,
# and the directory walk recurses upward to the filesystem root without
# stopping at a git boundary — so a stray variant is easy to create and
# hard to notice. Patterns are root-anchored with a leading `/` so a repo
# that legitimately uses `.config/` or a nested `mise/` directory for
# unrelated purposes is unaffected.
#
# `.envrc` and `.tool-versions` are deliberately absent: they are left in
# place and warned about, and ignoring them would be both ineffective (a
# tracked file stays tracked) and misleading.
write_gitignore_block() {
  local gi="$TARGET_DIR/.gitignore"

  if [ -f "$gi" ] && grep -Fq "$GITIGNORE_SENTINEL_BEGIN" "$gi"; then
    log "$gi already carries the mise block — no change."
    return 0
  fi

  # Separate the block from whatever precedes it, but do not add a leading
  # blank line to a file we are creating from scratch.
  if [ -s "$gi" ]; then
    printf '\n' >> "$gi"
  fi

  cat >> "$gi" <<EOF
$GITIGNORE_SENTINEL_BEGIN
# mise.toml is the ONE tracked config form; it is deliberately NOT
# ignored. Everything below is either machine-local or a
# non-canonical location we do not use.
/mise.local.toml
/mise/config.toml
/.mise/config.toml
/.config/mise.toml
/.config/mise/config.toml
/.config/mise/conf.d/
$GITIGNORE_SENTINEL_END
EOF
  log "Wrote the mise block to $gi"
}

# Report the ignore rule matching a path, if any, as `<source>:<line>:<pattern>`.
#
# `--no-index` so the answer is about the RULES alone, not about tracking
# state. That matters: git reports no ignore match for a TRACKED path by
# default, and "tracked AND ignore-ruled" is exactly the combination
# condition (c) below exists to call out — an ignore rule is inert against a
# path already in the index, so seeing both is the signal that someone added
# a rule expecting it to do something it cannot do.
ignore_rule_for() { # $1 = path relative to TARGET_DIR
  ( cd "$TARGET_DIR" && git check-ignore -v --no-index -- "$1" 2>/dev/null ) || true
}

is_tracked() { # $1 = path relative to TARGET_DIR
  ( cd "$TARGET_DIR" && git ls-files --error-unmatch -- "$1" >/dev/null 2>&1 )
}

# Report which of the three INDEPENDENT conditions a leftover file is in.
# They occur in any combination, and each has its own remedy — an ignore
# rule does not remove a file, and deleting a file does not remove either
# the rule or the index entry. Returns 0 if at least one condition held.
report_leftover_conditions() { # $1 = path relative to TARGET_DIR
  local rel="$1" rule any=0

  if [ -e "$TARGET_DIR/$rel" ]; then
    any=1
    printf '    (a) present on disk at %s.\n' "$TARGET_DIR/$rel"
    printf '        Remedy: delete it yourself once you are satisfied with the conversion. This script never does.\n'
  fi

  rule="$(ignore_rule_for "$rel")"
  if [ -n "$rule" ]; then
    any=1
    printf '    (b) matched by an ignore rule — %s\n' "$rule"
    printf '        Remedy: delete that rule. Left behind, it silently hides a re-created %s from `git status`.\n' "$rel"
  fi

  if is_tracked "$rel"; then
    any=1
    printf '    (c) tracked in git.\n'
    printf '        Remedy: `git rm %s` (or `git rm --cached %s` to keep the working copy) and commit.\n' "$rel" "$rel"
    printf '        An ignore rule cannot help here: .gitignore has no effect on a path already in the index.\n'
  fi

  [ "$any" -eq 1 ]
}

warn_repo_leftovers() {
  echo
  log "Per-repo asdf/direnv leftovers in $TARGET_DIR (NOT removed):"

  local found=0
  local header

  # .envrc
  header='  - .envrc — inert once direnv is uninstalled.'
  if report_leftover_conditions .envrc > /dev/null; then
    found=1
    printf '%s\n' "$header"
    # Anything beyond `use asdf` / `dotenv_if_exists` / comments / blanks
    # has no automatic mise equivalent and needs a manual `_.path` /
    # `_.source` decision, so show it.
    local envrc="$TARGET_DIR/.envrc" extra
    if [ -f "$envrc" ]; then
      extra="$(grep -Ev '^[[:space:]]*(#.*)?$|^[[:space:]]*use[[:space:]]+asdf[[:space:]]*$|^[[:space:]]*dotenv_if_exists[[:space:]]*$' "$envrc" || true)"
      if [ -n "$extra" ]; then
        printf '    It holds more than `use asdf` / `dotenv_if_exists`; these lines have no automatic mise equivalent\n'
        printf '    and need a manual [env] _.path / _.source decision in mise.toml:\n'
        printf '%s\n' "$extra" | sed 's/^/      /'
      fi
    fi
    report_leftover_conditions .envrc
  fi

  # .tool-versions
  header='  - .tool-versions — still LOADED by mise while it exists, and it still works.'
  if report_leftover_conditions .tool-versions > /dev/null; then
    found=1
    printf '%s\n' "$header"
    if [ -f "$TARGET_DIR/.tool-versions" ]; then
      printf '    mise merges the two files per tool: a tool in both resolves from mise.toml, but a tool present\n'
      printf '    ONLY in .tool-versions stays active from there. So anything the conversion missed keeps working\n'
      printf '    invisibly until you delete this file, at which point it vanishes.\n'
      printf '    Before deleting it, run `mise ls` and read the Config Source column: any tool still sourced from\n'
      printf '    .tool-versions is one mise.toml does not cover. Only delete it once that list is empty.\n'
    fi
    report_leftover_conditions .tool-versions
  fi

  [ "$found" -eq 0 ] && printf '  (none found)\n'
  return 0
}

verify() {
  echo
  log "== Verify (what actually resolved in $TARGET_DIR) =="
  ( cd "$TARGET_DIR" && "$MISE" cfg ) || warn "mise cfg failed"
  echo
  ( cd "$TARGET_DIR" && "$MISE" ls ) || warn "mise ls failed"
}

# --- Main -------------------------------------------------------------

require_mise || exit 1
require_repo_root

global_steps

echo
log "== Repo: $TARGET_DIR =="
generate_repo_config
write_gitignore_block
warn_repo_leftovers
verify

echo
log "Done. Nothing was deleted, untracked, or committed — review \`git diff\` before committing the .gitignore change."
