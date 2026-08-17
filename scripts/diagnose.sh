#!/usr/bin/env bash
# scripts/diagnose.sh — consolidated diagnostics (quiet, one pass)
set -euo pipefail

_filter_noise() {
  sed -E '
    /[Ss]aving session/Id;
    /\.\.\.copying shared history/Id;
    /[Ss]aving history/Id;
    /truncating history files/Id;
    /completed\./Id;
    /[Rr]estored session/Id;
  ' | awk "NF"
}

section() { echo "=== $1 ==="; }

section "SHELL (make)"
printf "SHELL=%s\n" "${SHELL:-unknown}"

section "PATH"
printf "%s\n" "$PATH"

section "tool locations"
(command -v brew   && brew --version | head -n1) || echo "brew not found"
(command -v mise   && mise --version           ) || echo "mise not found"
(command -v zoxide && zoxide --version         ) || echo "zoxide not found"
command -v zsh >/dev/null 2>&1 || echo "zsh not found"

section "mise config"
if command -v mise >/dev/null 2>&1; then mise cfg || echo "(mise cfg failed)"; else echo "(mise not available)"; fi

section ".zshrc hooks present?"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
if [[ -f "$ZSHRC" ]]; then
  grep -qE '^\s*source\s+~/\.aliases\.zsh' "$ZSHRC" && echo "source ~/.aliases.zsh" || echo "source ~/.aliases.zsh   (missing)"
  grep -qE 'zoxide init zsh' "$ZSHRC" && echo 'eval "$(zoxide init zsh)"' || echo 'eval "$(zoxide init zsh)" (missing)'
else
  echo "~/.zshrc not found at ${ZSHRC}"
fi

section "ZDOTDIR (from zsh -l)"
out="$(zsh -lic 'print -r -- ${ZDOTDIR:-""}' 2>/dev/null | _filter_noise)"
if [[ -n "$out" ]]; then echo "$out"; else echo "<empty>"; fi

section "z/zi functions loaded? (from zsh -l)"
zout="$(zsh -lic 'typeset -f z  >/dev/null && echo "z function is loaded"  || echo "z not loaded"; typeset -f zi >/dev/null && echo "zi function is loaded" || echo "zi not loaded"' 2>/dev/null | _filter_noise)"
if [[ -n "$zout" ]]; then echo "$zout"; fi

section "mise-resolved tools (from zsh -l)"
dout="$(zsh -lic 'command -v mise >/dev/null 2>&1 && mise ls --current || true' 2>/dev/null | _filter_noise)"
if [[ -n "$dout" ]]; then echo "$dout"; else echo "(mise not available or no tools resolved here)"; fi

section "m() alias available? (from zsh -l)"
zsh -lic 'typeset -f m >/dev/null && echo "m function is loaded" || echo "m not loaded"' 2>/dev/null | _filter_noise
