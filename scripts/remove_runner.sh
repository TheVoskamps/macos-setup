#!/usr/bin/env bash
# scripts/remove_runner.sh — execute one TIER's removal list by uninstalling
# each listed brew/cask/mas entry that is currently installed. Idempotent
# and tier-agnostic: callers invoke it once per (tier, mode) combination
# they care about.
#
# Usage: scripts/remove_runner.sh <tier-root> \
#          [--mode={uninstall|purge}] [--dry-run] [--banner=<text>]
#
# `<tier-root>` is a tier directory — `default/`, `profiles/<name>/`, or the
# external host tier. The entries come from that tier's
# `config.toml` `[profile] uninstall` (for `--mode=uninstall`) or
# `[profile] purge` (for `--mode=purge`) array. Before issue #33 the
# entries came from a numbered `Uninstall/NN-Uninstall.<slug>` /
# `RemoveAndPurge/NN-RemoveAndPurge.<slug>` file instead; the removal
# SEMANTICS are unchanged, only where the list is read from.
#
# Entry grammar (see parse_removal_entry in config_common.sh):
#   "brew:<formula>"    "cask:<token>"    "mas:<id>"    "mas:<id>:<Name>"
#
# Quiet-by-default for empty tiers (issue #167):
#   Most tiers remove nothing. To keep the removal loops — `make update`,
#   `make uninstall`, `make remove-and-purge`, and their dry-run companions —
#   readable, a tier with an EMPTY (or absent) array for the active mode
#   prints NOTHING by default — neither the optional `--banner` line the
#   caller passes nor the runner's own `Processing` / `Done` lines. A tier
#   with at least one entry prints fully, INCLUDING any
#   `skip: <pkg> not installed` lines (those are genuinely useful). Set the
#   VERBOSE env var to any non-empty value to restore ALL lines for EVERY
#   tier, including empty ones, for debugging.
#
#   This "does the tier remove anything?" decision lives in ONE place —
#   here, the only code that reads the array — so the caller's banner and
#   the runner's Processing/Done lines can never disagree about whether a
#   given tier is silent. The Makefile passes the banner text it would
#   otherwise have echoed itself via `--banner=<text>`.
#
# Modes:
#   --mode=uninstall (default): read `[profile] uninstall`; remove the
#       binary and leave user data on disk. For `cask:foo` this runs
#       `brew uninstall --cask foo`.
#   --mode=purge: read `[profile] purge`; also pass --zap to cask
#       uninstalls. For `cask:foo` this runs
#       `brew uninstall --cask --zap foo`, which also removes the cask's
#       declared user data (preferences, caches, login items).
#
#   The default mode is `uninstall`.
#
# Behavior in both modes:
#   - brew:foo        -> brew uninstall --formula foo   (if installed)
#   - cask:foo        -> brew uninstall --cask [--zap] foo (if installed)
#   - mas:NNNNN       -> sudo mas uninstall NNNNN       (if installed)
#                        (via "$SUDO" "$MAS"; see the override note)
#
#   - Skip messages are emitted when an entry is already absent.
#   - brew formula and cask uninstall failures are non-fatal-but-tracked:
#     processing continues, but the runner exits non-zero at the end so
#     callers (e.g. `make uninstall`) see a partially-failed run.
#   - mas uninstall failures are warn-only-untracked (best-effort): they
#     are logged but do not affect the runner's exit status.
#   - A malformed entry aborts the run with exit 2.
#   - --dry-run prints actions without executing anything; exits 0.
#
# Log lines are prefixed with the active mode (e.g. `[uninstall]` vs
# `[purge]`) so combined runs are unambiguous.
#
# Every external binary this script can DESTROY with is overridable by an
# env var of the same name, all in the one form install_filter.sh already
# used for brew (`VAR="${VAR:-default}"`), all defaulting to the binary on
# PATH:
#
#   BREW  the brew binary  (`BREW="${BREW:-brew}"`)
#   MAS   the mas binary   (`MAS="${MAS:-mas}"`)
#   SUDO  the sudo used to drive mas (`SUDO="${SUDO:-sudo}"`)
#
# EVERY shell-out goes through them — the `brew list` / `mas list` probes
# as well as the `brew uninstall` / `mas uninstall` calls — because a probe
# answered by the REAL binary is what decides whether a real uninstall
# follows. `SUDO` is overridable alongside `MAS` because the mas removal is
# `sudo mas uninstall`: stubbing only one half still runs the other for
# real. `make ... BREW=<stub> MAS=<stub> SUDO=<stub>` reaches this script
# because GNU make exports command-line variables into every recipe's
# environment. Do not reintroduce a bare `brew`, `mas`, or `sudo` call:
# scripts/test/remove_runner_brew_override_test.sh fails if you do.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

# Accumulator for non-fatal-but-tracked failures (brew formula/cask
# uninstall errors). Mirrors the pattern used by `make update` so a
# partially-failed run surfaces a non-zero exit. mas failures stay
# warn-only and do not touch FAIL.
FAIL=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <tier-root> [--mode={uninstall|purge}] [--dry-run] [--banner=<text>]

Uninstall every brew/cask/mas entry in the tier's config.toml
[profile] uninstall (or purge) array that is currently installed.

  --mode=uninstall (default)  remove the binary; leave user data on disk
  --mode=purge                also pass --zap to cask uninstalls
                              (removes the cask's declared user data)
  --dry-run                   print actions without executing
  --banner=<text>             one line to echo before processing, unless
                              the tier's array is empty and VERBOSE is
                              unset (then the whole tier stays silent)
EOF
  exit 64
}

DRY_RUN=0
MODE="uninstall"
TIER=""
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
      if [[ -n "$TIER" ]]; then
        echo "[remove_runner] Multiple tiers given: $TIER and $arg" >&2
        usage
      fi
      TIER="$arg"
      ;;
  esac
done

if [[ -z "$TIER" ]]; then
  usage
fi

# A tier that does not exist on disk removes nothing. This is a normal
# state, not an error: the host tier is absent until it is seeded, and a
# profile in the host's list may be unknown (install_filter.sh warns; make
# verify hard-errors). Exit silently so the removal loops stay quiet.
if [[ ! -d "$TIER" ]]; then
  exit 0
fi

TIER_LABEL="$(tier_label "$REPO_ROOT" "$TIER")"

# --- Helpers ---
log() {
  echo "[$MODE] $*"
}

# Collect this tier's entries for the active mode, parsed, one
# "<kind>\t<identifier>\t<label>" record per line. A malformed entry aborts.
ENTRIES="$(mktemp)"
trap 'rm -f "$ENTRIES"' EXIT
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  if ! parse_removal_entry "$entry" >> "$ENTRIES"; then
    echo "[$MODE] ERROR: $TIER/config.toml [profile] $MODE: $entry" >&2
    exit 2
  fi
done < <(read_removals "$TIER" "$MODE")

# QUIET=1 means: suppress the banner and the Processing/Done lines for
# this (empty) tier. VERBOSE (any non-empty value) forces full output for
# every tier, including empty ones, for debugging.
QUIET=0
if [[ -z "${VERBOSE:-}" ]] && [[ ! -s "$ENTRIES" ]]; then
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

# The brew binary to use for every probe and every uninstall. Overridable
# via the BREW env var so tests can stub it (the same knob the Makefile
# exposes as `BREW=`, and the same convention install_filter.sh uses);
# defaults to whatever `brew` is on PATH.
BREW="${BREW:-brew}"

# The mas binary, and the sudo that drives it, for every probe and every
# uninstall — same knob, same reason as BREW. Both halves are overridable
# because `sudo mas uninstall` needs both to be stubbed before a test is
# actually safe: stub only MAS and the real sudo still runs (and prompts);
# stub only SUDO and the real mas is what it runs.
MAS="${MAS:-mas}"
SUDO="${SUDO:-sudo}"

# Stop `brew uninstall` from cascading into shared dependencies (issue #37).
# By default `brew uninstall` follows up with an automatic `brew autoremove`,
# which removes every formula nothing declares a dependency on any more. That
# is how uninstalling asdf took Homebrew's `bash` formula with it mid-run, and
# a run that deletes the interpreter its own later steps need cannot finish.
# This runner is the ONE place both removal modes actually call brew, so
# exporting it here covers `make uninstall`, `make remove-and-purge`, `make
# update`'s two loops, and the version-managers purge `make install` applies
# inline. Removing genuinely unneeded dependencies stays available as a
# deliberate, separate `brew autoremove`.
export HOMEBREW_NO_AUTOREMOVE=1

is_brew_installed() {
  "$BREW" list --formula "$1" >/dev/null 2>&1
}

is_cask_installed() {
  "$BREW" list --cask "$1" >/dev/null 2>&1
}

is_mas_installed() {
  command -v "$MAS" >/dev/null 2>&1 && "$MAS" list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

uninstall_brew() {
  local name="$1"
  if is_brew_installed "$name"; then
    if ! run "$BREW" uninstall --formula "$name"; then
      log "WARNING: $BREW uninstall --formula $name failed — continuing"
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
      if ! run "$BREW" uninstall --cask --zap "$name"; then
        log "WARNING: $BREW uninstall --cask --zap $name failed — continuing"
        FAIL=1
      fi
    else
      if ! run "$BREW" uninstall --cask "$name"; then
        log "WARNING: $BREW uninstall --cask $name failed — continuing"
        FAIL=1
      fi
    fi
  else
    log "skip: $name not installed (cask)"
  fi
}

uninstall_mas() {
  local id="$1" name="$2"
  if ! command -v "$MAS" >/dev/null 2>&1; then
    log "skip: $name (id $id) — mas CLI not found: $MAS"
    return 0
  fi
  if is_mas_installed "$id"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: $SUDO $MAS uninstall $id   # $name"
      return 0
    fi
    log "RUN: $SUDO $MAS uninstall $id   # $name"
    if ! "$SUDO" "$MAS" uninstall "$id"; then
      log "WARNING: $SUDO $MAS uninstall failed for $name (id $id) — continuing"
    fi
  else
    log "skip: $name (id $id) not installed"
  fi
}

# --- Main loop ---
# Emit the caller-supplied banner first (the `==> Applying ...` line the
# Makefile would otherwise have echoed itself), then the Processing line.
# Both are suppressed for an empty tier in quiet mode so the banner and
# the runner's lines stay in lockstep — never one without the other.
if [[ "$QUIET" -eq 0 ]]; then
  [[ -n "$BANNER" ]] && echo "$BANNER"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Processing $TIER_LABEL (dry-run)"
  else
    log "Processing $TIER_LABEL"
  fi
fi

while IFS=$'\t' read -r kind id label; do
  [[ -n "$kind" ]] || continue
  case "$kind" in
    brew) uninstall_brew "$id" ;;
    cask) uninstall_cask "$id" ;;
    mas)  uninstall_mas "$id" "$label" ;;
  esac
done < "$ENTRIES"

[[ "$QUIET" -eq 0 ]] && log "Done: $TIER_LABEL"
exit $FAIL
