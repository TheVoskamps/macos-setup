#!/usr/bin/env bash
# scripts/apply_tier.sh — apply ONE tier: its `Brewfile` (through the smart
# filter, then `brew bundle`), then its `[profile] post_install` commands,
# in declared order.
#
# Usage: scripts/apply_tier.sh <tier-root>
#
# `<tier-root>` is a tier directory — `default/` (the core tier),
# `profiles/<name>/`, or the external host tier (see host_tier_dir in
# config_common.sh).
#
# This is the single chokepoint every install path routes through:
# `make install` (once per tier, in tier order), `make profile <name>...`
# (once per named profile), `make core`, and `make update`'s
# version-managers install step. Keeping the body here rather than inlined
# in each Makefile recipe is what stops those paths from drifting.
#
# FAILURE TOLERANCE. A failing `brew bundle`, and a failing post-install
# command, are each reported and TRACKED, never fatal: the run continues to
# the next step and the script exits non-zero at the end. That matters
# because the caller applies tiers in a loop — an early tier's failure must
# not skip the later tiers — and because the post-install commands are
# independent of one another. The caller accumulates these non-zero exits
# into its own end-of-run summary.
#
# QUIET BY DEFAULT. A tier with no Brewfile, and a tier with no
# post_install entries, say nothing about it. Those negative-case lines are
# gated behind the VERBOSE env var, because a host that opts into many
# profiles would otherwise bury the real signal under one "no Brewfile
# here" line per tier. `VERBOSE=1` restores them for debugging "why didn't
# my profile apply?". The positive `==> Applying ...` lines and every
# failure line always print. The same gate lives in remove_runner.sh for
# the removal side.
#
# The brew binary is overridable via the BREW env var (the same knob the
# Makefile exposes as `BREW=` and install_filter.sh / remove_runner.sh
# honor), so tests can stub it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <tier-root>" >&2
  exit 64
fi

TIER="$1"
BREW="${BREW:-brew}"
INSTALL_FILTER="$SCRIPT_DIR/install_filter.sh"

# A tier that does not exist on disk contributes nothing. Normal state, not
# an error: the host tier is absent until seeded, and a profile named in the
# host's list may be unknown (make verify hard-errors on that; install only
# warns).
if [[ ! -d "$TIER" ]]; then
  [[ -n "${VERBOSE:-}" ]] && echo "==> No such tier directory: $TIER"
  exit 0
fi

LABEL="$(tier_label "$REPO_ROOT" "$TIER")"
FAIL=0

# --- 1. Brewfile --------------------------------------------------------
BREWFILE="$TIER/Brewfile"
if [[ -f "$BREWFILE" ]]; then
  echo "==> Applying $LABEL Brewfile (filtered): $BREWFILE"
  if tmp="$("$INSTALL_FILTER" "$BREWFILE")"; then
    if ! "$BREW" bundle --file="$tmp"; then
      echo "==> FAILED: brew bundle for $LABEL ($BREWFILE)" >&2
      FAIL=1
    fi
    rm -f "$tmp"
  else
    echo "==> FAILED: could not filter $BREWFILE" >&2
    FAIL=1
  fi
else
  [[ -n "${VERBOSE:-}" ]] && echo "==> No Brewfile found at $BREWFILE"
fi

# --- 2. post_install ----------------------------------------------------
# Each entry is a repo-root-relative script path plus optional arguments,
# e.g. "scripts/vscode_extensions.sh code". Word-split on whitespace: these
# are hand-written config values, not user input, and quoting inside an
# entry is deliberately not supported — a command that needs it belongs in
# a script of its own.
any_hook=0
while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  any_hook=1
  # shellcheck disable=SC2206  # deliberate word-split; see above
  parts=($cmd)
  script="$REPO_ROOT/${parts[0]}"
  if [[ ! -x "$script" ]]; then
    echo "==> [$LABEL] post_install: ${parts[0]} not found or not executable — skipping" >&2
    FAIL=1
    continue
  fi
  echo "==> [$LABEL] post_install: $cmd"
  if ! ( cd "$REPO_ROOT" && "$script" "${parts[@]:1}" ); then
    echo "==> FAILED: [$LABEL] post_install: $cmd" >&2
    FAIL=1
  fi
done < <(read_post_install "$TIER")

if [[ "$any_hook" -eq 0 && -n "${VERBOSE:-}" ]]; then
  echo "==> No post_install entries for $LABEL"
fi

exit $FAIL
