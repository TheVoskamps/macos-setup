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
(command -v asdf   && asdf --version           ) || echo "asdf not found"
(command -v direnv && direnv --version         ) || echo "direnv not found"
(command -v zoxide && zoxide --version         ) || echo "zoxide not found"
command -v zsh >/dev/null 2>&1 || echo "zsh not found"

section ".tool-versions"
if [[ -f .tool-versions ]]; then cat .tool-versions; else echo "(none)"; fi

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

section "direnv status (from zsh -l)"
dout="$(zsh -lic 'command -v direnv >/dev/null 2>&1 && direnv status || true' 2>/dev/null | _filter_noise)"
if [[ -n "$dout" ]]; then echo "$dout"; else echo "(direnv not available or not enabled)"; fi

section "m() alias available? (from zsh -l)"
zsh -lic 'typeset -f m >/dev/null && echo "m function is loaded" || echo "m not loaded"' 2>/dev/null | _filter_noise
