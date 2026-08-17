#!/usr/bin/env bash
# strip_asdf_zshrc_lines.sh — remove the ~/.zshrc init lines that the
# asdf+direnv -> mise migration orphans.
#
# The forms below were all written by earlier runs of
# scripts/shell_setup.sh, and all are inert or broken once asdf and direnv
# are uninstalled:
#   a. `. /opt/homebrew/opt/asdf/libexec/asdf.sh` — already dead before the
#      migration (asdf 0.16+ is a single Go binary with no libexec/asdf.sh
#      to source), and it errors on every shell startup.
#   b. the asdf shims PATH export.
#   c. the direnv hook.
#
# More than one caller, because the cutover reaches a host down either of
# the paths below and each must leave ~/.zshrc clean:
#   - scripts/shell_setup.sh (the `03-Install.shell` post-install action),
#     i.e. `make install` and `make shell`.
#   - the `update` Makefile target, which uninstalls asdf and direnv via the
#     RemoveAndPurge loop but never runs shell_setup.sh.
#
# ZSHRC_PATH is overridable so the test suite can point it at a fixture.
#
# Run: bash scripts/strip_asdf_zshrc_lines.sh

set -euo pipefail

ZSHRC_PATH="${ZSHRC_PATH:-$HOME/.zshrc}"

# Each pattern is anchored to the exact active form shell_setup.sh wrote.
# Indented or commented variants ("    . .../asdf.sh",
# "# eval \"$(direnv hook zsh)\"") are deliberately preserved in case the
# user hand-edited their ~/.zshrc to keep a line for reference — those
# variants are inert and safe to leave alone. Do not loosen the anchors.
#
# These are ERE, written for `grep -E`. They contain literal `/`, which is
# also sed's own `/address/d` delimiter, so the sed form below escapes them
# rather than reusing the pattern verbatim — an unescaped `/` makes BSD sed
# abort with "invalid command code", which under `set -e` used to kill the
# caller on exactly the hosts this strip exists to fix.
_MS_ORPHANS=(
  '^\. .*/opt/asdf/libexec/asdf\.sh[[:space:]]*$'
  '^export PATH="[$][{]ASDF_DATA_DIR:-[$]HOME/[.]asdf[}]/shims:[$]PATH"[[:space:]]*$'
  '^eval "[$][(]direnv hook zsh[)]"[[:space:]]*$'
)

[ -f "$ZSHRC_PATH" ] || exit 0

# Guarded on at least one pattern matching, so a host that has already
# migrated is a no-op on re-run and gains no stray .bak.
_ms_found_orphan=0
for _ms_pat in "${_MS_ORPHANS[@]}"; do
  if grep -Eq "$_ms_pat" "$ZSHRC_PATH"; then _ms_found_orphan=1; fi
done
[ "$_ms_found_orphan" -eq 1 ] || exit 0

# Portable in-place edit via `sed -i.bak`, which writes the backup natively
# (consistent with the rest of shell_setup.sh's ~/.zshrc mutations).
# `sed -i.bak` rather than a `grep -Ev` pipeline avoids a subtle
# `set -euo pipefail` trap: `grep -Ev` exits 1 when its output is empty
# (i.e. every input line matched), which would abort before the caller's
# remaining work -- leaving the orphaned lines in place. `sed -d` has no
# such failure mode.
_ms_sed_args=()
for _ms_pat in "${_MS_ORPHANS[@]}"; do
  _ms_sed_args+=(-e "/${_ms_pat//\//\\/}/d")
done
sed -i.bak -E "${_ms_sed_args[@]}" "$ZSHRC_PATH"
echo "[SHELL-SETUP] Removed orphaned asdf/direnv init lines from $ZSHRC_PATH (backup at $ZSHRC_PATH.bak)"
