#!/usr/bin/env bash
# ensure_mise_zshrc_lines.sh — add the mise init lines to ~/.zshrc, once.
#
# Both forms are emitted, on purpose:
#   - `mise activate zsh` is mise's preferred interactive form and is what
#     makes `cd` into a project switch tool versions (and, with
#     `[settings] env_file`, load its `.env`).
#   - the shims dir on PATH covers every non-interactive context that never
#     sources ~/.zshrc at all.
#
# The shims path is mise's own default install location. The literal below is
# written into ~/.zshrc, so it cannot be sourced from `mise_shims_dir` in
# scripts/mise_common.sh; that function states the same path, and
# scripts/launchagent_runner.sh repeats the literal a third time to put the
# directory on PATH for scheduled jobs (launchd does NOT source ~/.zshrc).
# Change one, change all three.
#
# This is the ADD half of the asdf -> mise cutover's ~/.zshrc work;
# scripts/strip_asdf_zshrc_lines.sh is the REMOVE half. Both are their own
# script for the same reason: the cutover reaches a host down either of two
# paths, and each must leave ~/.zshrc in the same state (issue #38).
#   - scripts/shell_setup.sh (the `03-Install.shell` post-install action),
#     i.e. `make install` and `make shell`.
#   - the `update` Makefile target, which installs mise and uninstalls
#     asdf/direnv but never runs shell_setup.sh. Without this call a host
#     that only ever runs `make update` ends the cutover with mise installed,
#     the old version manager gone, and NO version manager wired into the
#     interactive shell.
#
# The activation line is gated on mise actually being reachable: a ~/.zshrc
# that evals an absent binary errors on every shell startup, which is the
# failure this whole cutover exists to avoid. The shims PATH export is not
# gated — a PATH entry pointing at a directory that does not exist yet is
# inert, and it is correct the moment mise lands.
#
# ZSHRC_PATH is overridable so the test suite can point it at a fixture, and
# MISE is overridable (the same knob scripts/mise_common.sh reads) so a test
# can drive both the reachable and unreachable branches. MISE gates the
# reachability decision ONLY — the line written into ~/.zshrc always names
# bare `mise`, because that is what the user's interactive shell will find.
#
# Run: /bin/bash scripts/ensure_mise_zshrc_lines.sh

set -euo pipefail

ZSHRC_PATH="${ZSHRC_PATH:-$HOME/.zshrc}"
MISE="${MISE:-mise}"

_ms_ensure_line() {
  local line="$1" file="$2"
  [ -f "$file" ] || touch "$file"
  if ! grep -Fqx "$line" "$file" 2>/dev/null; then
    echo "$line" >> "$file"
    echo "[SHELL-SETUP] appended to $file: $line"
  fi
}

_ms_ensure_line 'export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"' "$ZSHRC_PATH"

if command -v "$MISE" >/dev/null 2>&1; then
  _ms_ensure_line 'eval "$(mise activate zsh)"' "$ZSHRC_PATH"
else
  echo "[SHELL-SETUP] NOTE: mise not yet installed; activation line will be added after install."
fi
