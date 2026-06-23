#!/usr/bin/env bash
# scripts/remove_runner.sh — execute a single Uninstall/<NN-Uninstall.suffix>
# or RemoveAndPurge/<NN-RemoveAndPurge.suffix> file by uninstalling each
# listed brew/cask/mas entry that is currently installed. Idempotent and
# tier-agnostic: callers are responsible for invoking it once per
# (tier, file) combination they care about.
#
# Usage: scripts/remove_runner.sh <path-to-removal-file> \
#          [--mode={uninstall|purge}] [--dry-run] [--banner=<text>]
#
# Quiet-by-default for empty slots (issue #167):
#   Most numbered slot files are just a comment header with no actual
#   package to remove. To keep the removal loops — `make update`,
#   `make uninstall`, `make remove-and-purge`, and their dry-run
#   companions — readable, a slot file with
#   ZERO active directives (no uncommented brew/cask/mas line) prints
#   NOTHING by default — neither the optional `--banner` line the caller
#   passes nor the runner's own `Processing` / `Done` lines. A slot file
#   that HAS at least one active directive prints fully, INCLUDING any
#   `skip: <pkg> not installed` lines (those are genuinely useful). Set
#   the VERBOSE env var to any non-empty value to restore ALL lines for
#   EVERY slot, including empty ones, for debugging.
#
#   This "does the file have an active directive?" decision lives in ONE
#   place — here, the only code that reads the file — so the caller's
#   banner and the runner's Processing/Done lines can never disagree about
#   whether a given slot+tier is silent. The Makefile passes the banner
#   text it would otherwise have echoed itself via `--banner=<text>`.
#
# Modes:
#   --mode=uninstall (default): remove the binary; leave user data on
#       disk. For `cask 'foo'` this runs `brew uninstall --cask foo`.
#   --mode=purge: also pass --zap to cask uninstalls. For
#       `cask 'foo'` this runs `brew uninstall --cask --zap foo`,
#       which also removes the cask's declared user data
#       (preferences, caches, login items).
#
#   The default mode is `uninstall`; this preserves the previous
#   uninstall behavior so any out-of-tree caller continues to work
#   without changes.
#
# Behavior in both modes:
#   - brew 'foo'                 -> brew uninstall --formula foo (if installed)
#   - mas 'Name', id: NNNNN      -> sudo mas uninstall NNNNN     (if installed)
#   - tap '...'                  -> ignored
#   - blank lines / comments     -> ignored
#
#   - Skip messages are emitted when an entry is already absent.
#   - brew formula and cask uninstall failures are non-fatal-but-tracked:
#     processing continues, but the runner exits non-zero at the end so
#     callers (e.g. `make uninstall`) see a partially-failed run.
#   - mas uninstall failures are warn-only-untracked (best-effort): they
#     are logged but do not affect the runner's exit status.
#   - Malformed lines or unsupported directives abort the run with exit 2.
#   - --dry-run prints actions without executing anything; exits 0.
#
# Log lines are prefixed with the active mode (e.g. `[uninstall]` vs
# `[purge]`) so combined runs are unambiguous.

set -uo pipefail

# Accumulator for non-fatal-but-tracked failures (brew formula/cask
# uninstall errors). Mirrors the pattern used by `make update` so a
# partially-failed run surfaces a non-zero exit. mas failures stay
# warn-only and do not touch FAIL.
FAIL=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <path-to-removal-file> [--mode={uninstall|purge}] [--dry-run] [--banner=<text>]

Uninstall every brew/cask/mas entry listed in the given file that is
currently installed. tap directives are ignored.

  --mode=uninstall (default)  remove the binary; leave user data on disk
  --mode=purge                also pass --zap to cask uninstalls
                              (removes the cask's declared user data)
  --dry-run                   print actions without executing
  --banner=<text>             one line to echo before processing, unless
                              the file has no active directive and VERBOSE
                              is unset (then the whole slot stays silent)
EOF
  exit 64
}

DRY_RUN=0
MODE="uninstall"
FILE=""
BANNER=""

# --- Arg parsing ---
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --mode=uninstall) MODE="uninstall" ;;
    --mode=purge)     MODE="purge" ;;
    --mode=*)
      echo "[remove_runner] Unknown --mode value: ${arg#--mode=}" >&2
      usage
      ;;
    --banner=*) BANNER="${arg#--banner=}" ;;
    -h|--help) usage ;;
    -*)
      echo "[remove_runner] Unknown flag: $arg" >&2
      usage
      ;;
    *)
      if [[ -n "$FILE" ]]; then
        echo "[remove_runner] Multiple files given: $FILE and $arg" >&2
        usage
      fi
      FILE="$arg"
      ;;
  esac
done

if [[ -z "$FILE" ]]; then
  usage
fi

if [[ ! -f "$FILE" ]]; then
  echo "[$MODE] File not found: $FILE" >&2
  exit 2
fi

# --- Helpers ---
log() {
  echo "[$MODE] $*"
}

# Static check: does the file have at least one ACTIVE directive — an
# uncommented, non-blank brew/cask/mas line? Used to decide whether this
# slot+tier prints anything at all in the common quiet (non-VERBOSE) case.
# Mirrors the per-line parse below (strip trailing comments + whitespace,
# then match the brew/cask/mas keyword) so the gate and the parse loop
# agree on what counts as "active". tap lines do NOT count — the runner
# ignores them, so a tap-only file has nothing to do.
has_active_directive() {
  local raw line
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^(brew|cask|mas)[[:space:]] ]]; then
      return 0
    fi
  done < "$FILE"
  return 1
}

# QUIET=1 means: suppress the banner and the Processing/Done lines for
# this (empty) slot. VERBOSE (any non-empty value) forces full output for
# every slot, including empty ones, for debugging.
QUIET=0
if [[ -z "${VERBOSE:-}" ]] && ! has_active_directive; then
  QUIET=1
fi

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  log "RUN: $*"
  "$@"
}

is_brew_installed() {
  brew list --formula "$1" >/dev/null 2>&1
}

is_cask_installed() {
  brew list --cask "$1" >/dev/null 2>&1
}

is_mas_installed() {
  command -v mas >/dev/null 2>&1 && mas list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

uninstall_brew() {
  local name="$1"
  if is_brew_installed "$name"; then
    if ! run brew uninstall --formula "$name"; then
      log "WARNING: brew uninstall --formula $name failed — continuing"
      FAIL=1
    fi
  else
    log "skip: $name not installed (brew formula)"
  fi
}

uninstall_cask() {
  local name="$1"
  if is_cask_installed "$name"; then
    if [[ "$MODE" == "purge" ]]; then
      if ! run brew uninstall --cask --zap "$name"; then
        log "WARNING: brew uninstall --cask --zap $name failed — continuing"
        FAIL=1
      fi
    else
      if ! run brew uninstall --cask "$name"; then
        log "WARNING: brew uninstall --cask $name failed — continuing"
        FAIL=1
      fi
    fi
  else
    log "skip: $name not installed (cask)"
  fi
}

uninstall_mas() {
  local name="$1" id="$2"
  if ! command -v mas >/dev/null 2>&1; then
    log "skip: $name (id $id) — mas CLI not installed"
    return 0
  fi
  if is_mas_installed "$id"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: sudo mas uninstall $id   # $name"
      return 0
    fi
    log "RUN: sudo mas uninstall $id   # $name"
    if ! sudo mas uninstall "$id"; then
      log "WARNING: mas uninstall failed for $name (id $id) — continuing"
    fi
  else
    log "skip: $name (id $id) not installed"
  fi
}

# --- Main parse loop ---
# Emit the caller-supplied banner first (the `==> Applying ...` line the
# Makefile would otherwise have echoed itself), then the Processing line.
# Both are suppressed for an empty slot in quiet mode so the banner and
# the runner's lines stay in lockstep — never one without the other.
if [[ "$QUIET" -eq 0 ]]; then
  [[ -n "$BANNER" ]] && echo "$BANNER"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Processing $FILE (dry-run)"
  else
    log "Processing $FILE"
  fi
fi

lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  lineno=$((lineno + 1))

  # Strip trailing comments and surrounding whitespace.
  line="${raw%%#*}"
  line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -z "$line" ]] && continue

  if [[ "$line" =~ ^tap[[:space:]]+[\"\'][^\"\']+[\"\'] ]]; then
    # tap directives are intentionally ignored.
    continue
  fi

  if [[ "$line" =~ ^brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
    uninstall_brew "${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "$line" =~ ^cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
    uninstall_cask "${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "$line" =~ ^mas[[:space:]]+[\"\']([^\"\']+)[\"\'][[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]]; then
    uninstall_mas "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    continue
  fi

  echo "[$MODE] ERROR: $FILE:$lineno: malformed or unsupported directive: $line" >&2
  exit 2
done < "$FILE"

[[ "$QUIET" -eq 0 ]] && log "Done: $FILE"
exit $FAIL
