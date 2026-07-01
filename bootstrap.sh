#!/usr/bin/env bash
# bootstrap.sh
# Combined minimal bootstrap for macOS.
# Order:
#   1) Install Homebrew
#   2) Install mas (via Homebrew)
#   3) Install dasel (via Homebrew) — the TOML query primitive config.toml relies on
#   4) Add zsh aliases for brew/mas (before any checks that might use them)
#   5) Ensure Apple Command Line Tools (git)
#   6) Check MAS login (non-fatal if not signed in)
#   7) Clone this (public) repository over HTTPS
#
# Notes:
# - Idempotent: Safe to re-run.
# - Aliases are written to ~/.zprofile and ~/.zshrc (and $ZDOTDIR equivalents) only if missing.
# - MAS login check will open App Store if GUI is available; over pure SSH it will just warn.
# - This repo is public, so the clone is a plain HTTPS clone — no SSH key,
#   no 1Password SSH agent, no GitHub SSH auth needed. The 1Password
#   SSH-agent setup that this script used to walk you through is preserved
#   as reference in docs/1password-as-ssh-agent.md (still useful when you
#   DO need SSH auth — e.g. pushing to this repo or cloning private repos).

set -euo pipefail

log() { printf "\033[1;32m[BOOTSTRAP]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }

# Step wrapper
step() {
  local name="$1"; shift
  log "▶ ${name}"
  if "$@"; then
    log "✔ ${name}"
  else
    err "✖ ${name}"
    return 1
  fi
}

# macOS guard
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only."
  exit 1
fi

detect_profile_file() {
  if [[ -n "${ZDOTDIR:-}" && -f "${ZDOTDIR}/.zprofile" ]]; then
    echo "${ZDOTDIR}/.zprofile"
  elif [[ -f "$HOME/.zprofile" ]]; then
    echo "$HOME/.zprofile"
  elif [[ -f "$HOME/.bash_profile" ]]; then
    echo "$HOME/.bash_profile"
  else
    echo "$HOME/.profile"
  fi
}

PROFILE_FILE="$(detect_profile_file)"

ensure_brew_in_path() {
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    if ! grep -q 'homebrew/bin' "$PROFILE_FILE" 2>/dev/null; then
      {
        echo ''
        echo '# Homebrew'
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
      } >> "$PROFILE_FILE"
      log "Added Homebrew shellenv to $PROFILE_FILE"
    fi
  elif [[ -x "/usr/local/bin/brew" ]]; then
    export PATH="/usr/local/bin:$PATH"
    if ! grep -q '/usr/local/bin' "$PROFILE_FILE" 2>/dev/null; then
      {
        echo ''
        echo '# Homebrew (Intel)'
        echo 'export PATH="/usr/local/bin:$PATH"'
      } >> "$PROFILE_FILE"
      log "Added /usr/local/bin to PATH in $PROFILE_FILE"
    fi
  fi
  command -v brew >/dev/null 2>&1 || { err "brew not on PATH after install."; exit 1; }
}

install_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    log "Homebrew already installed."
  else
    log "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  ensure_brew_in_path
  brew update
}

install_mas() {
  # HOMEBREW_NO_ASK avoids the Homebrew 6.0+ interactive ask-mode prompt
  # (issue #20); bootstrap runs before .zshrc gains the export.
  HOMEBREW_NO_ASK=1 brew install mas || HOMEBREW_NO_ASK=1 brew upgrade mas || true
}

# dasel is the TOML query primitive every config.toml consumer relies on
# (scripts/config_common.sh and the mailer/cron/claude readers). It is
# installed here, alongside Homebrew/mas/git, so consumers can
# read config.toml unconditionally with no graceful-degradation branch.
#
# The read layer in scripts/config_common.sh targets the dasel v3 query
# contract specifically (v2->v3 was a total breaking change). We assert
# the installed dasel is EXACTLY major 3 here and fail loudly otherwise,
# so a Homebrew that ships a v2 or a future v4 is caught at provision time
# rather than silently breaking every config.toml read later. The `||
# true` that used to swallow a failed install is gone: a failed dasel
# install must NOT be silently ignored. Idempotent: brew install/upgrade
# is a no-op when dasel is already current.
install_dasel() {
  # HOMEBREW_NO_ASK avoids the Homebrew 6.0+ interactive ask-mode prompt
  # (issue #20); bootstrap runs before .zshrc gains the export.
  HOMEBREW_NO_ASK=1 brew install dasel || HOMEBREW_NO_ASK=1 brew upgrade dasel

  if ! command -v dasel >/dev/null 2>&1; then
    err "dasel not on PATH after brew install/upgrade; config.toml reads require dasel v3."
    return 1
  fi

  # v3 `dasel version` prints a bare version (e.g. 3.11.0) and exits 0.
  local raw major
  raw="$(dasel version 2>/dev/null)" || {
    err "\`dasel version\` failed; cannot confirm dasel v3 (required for config.toml reads)."
    return 1
  }
  raw="${raw%%[[:space:]]*}"
  major="${raw%%.*}"
  if [[ "$major" != "3" ]]; then
    err "dasel major version '$major' installed ($raw), but config.toml reads require EXACTLY v3. Pin/install dasel v3 before continuing."
    return 1
  fi
  log "dasel v$raw confirmed (v3 contract)."
}

ensure_zsh_aliases() {
  local BREW_BIN MAS_BIN
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    BREW_BIN="/usr/local/bin/brew"
  else
    BREW_BIN="$(command -v brew || true)"
  fi

  if [[ -n "$BREW_BIN" && -x "$BREW_BIN" ]]; then
    local PREFIX="$("$BREW_BIN" --prefix 2>/dev/null || echo "")"
    if [[ -n "$PREFIX" && -x "$PREFIX/bin/mas" ]]; then
      MAS_BIN="$PREFIX/bin/mas"
    elif command -v mas >/dev/null 2>&1; then
      MAS_BIN="$(command -v mas)"
    elif [[ -x "/opt/homebrew/bin/mas" ]]; then
      MAS_BIN="/opt/homebrew/bin/mas"
    elif [[ -x "/usr/local/bin/mas" ]]; then
      MAS_BIN="/usr/local/bin/mas"
    else
      MAS_BIN=""
    fi
  fi

  local FILES=()
  if [[ -n "${ZDOTDIR:-}" ]]; then
    FILES+=("${ZDOTDIR}/.zprofile" "${ZDOTDIR}/.zshrc")
  fi
  FILES+=("$HOME/.zprofile" "$HOME/.zshrc")

  for f in "${FILES[@]}"; do
    [[ -e "$f" ]] || touch "$f"
    if [[ -n "$BREW_BIN" && -x "$BREW_BIN" ]]; then
      if ! grep -qE '^[[:space:]]*alias[[:space:]]+brew=' "$f"; then
        echo "alias brew='$BREW_BIN'" >> "$f"
        log "Added alias for brew in $f"
      fi
    fi
    if [[ -n "$MAS_BIN" && -x "$MAS_BIN" ]]; then
      if ! grep -qE '^[[:space:]]*alias[[:space:]]+mas=' "$f"; then
        echo "alias mas='$MAS_BIN'" >> "$f"
        log "Added alias for mas in $f"
      fi
    fi
  done
}

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Apple Command Line Tools already installed."
    return 0
  fi

  # Try non-interactive softwareupdate path first
  warn "Installing Apple Command Line Tools (this can take a while)..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local LABEL
  LABEL="$(/usr/sbin/softwareupdate -l 2>/dev/null | grep -E 'Command Line Tools' | tail -1 | sed -E 's/^\s*\*\s*Label:\s*([^,]+),.*/\1/')"
  if [[ -n "${LABEL:-}" ]]; then
    if /usr/sbin/softwareupdate -i "$LABEL" -v; then
      rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      log "Apple Command Line Tools installed via softwareupdate."
      return 0
    fi
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress || true

  # Fallback: interactive dialog (requires GUI)
  warn "Falling back to 'xcode-select --install' (may require GUI interaction)."
  xcode-select --install || true
  return 0
}

check_mas_login() {
  if mas account >/dev/null 2>&1; then
    log "MAS signed in: $(mas account || true)"
    return 0
  else
    warn "Not signed into the Mac App Store."
    warn "Open the App Store app, sign in, then re-run this step or continue with Homebrew-only steps."
    open -a "App Store" >/dev/null 2>&1 || true
    return 0  # non-fatal
  fi
}

clone_repository() {
  # This repo is public, so a plain HTTPS clone needs no credentials.
  local repo_url="https://github.com/TheVoskamps/macos-setup.git"
  local target_dir="./macos-setup"

  if [[ -d "$target_dir" ]]; then
    log "Repository already exists at $target_dir"
    return 0
  fi

  log "Cloning repository to $target_dir..."
  if git clone "$repo_url" "$target_dir"; then
    log "Repository cloned successfully to $target_dir"
    log "Next steps:"
    log "  cd $target_dir"
    log "  make install"
    return 0
  else
    err "Failed to clone repository over HTTPS. Check your network connection and try again."
    return 1
  fi
}

main() {
  step "Install Homebrew" install_homebrew
  step "Install mas (brew)" install_mas
  step "Install dasel (brew)" install_dasel
  step "Add zsh aliases (brew, mas)" ensure_zsh_aliases
  step "Ensure Apple Command Line Tools" ensure_xcode_clt
  step "Check MAS login" check_mas_login
  step "Clone repository (HTTPS)" clone_repository

  log "Bootstrap complete. Open a new shell (or 'exec zsh -l') to load aliases."
  log "Next: cd macos-setup && make install"
}

main "$@"
