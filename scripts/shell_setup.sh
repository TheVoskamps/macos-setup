#!/usr/bin/env bash
# Idempotent shell setup for zsh + plugins + theme + aliases (Homebrew-based)
set -euo pipefail

log()  { printf "\033[1;32m[SHELL-SETUP]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }

BREW="$(command -v brew || true)"
if [[ -z "$BREW" ]]; then
  # try common paths
  [[ -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
  [[ -z "$BREW" && -x /usr/local/bin/brew ]] && BREW=/usr/local/bin/brew
fi
if [[ -z "$BREW" ]]; then
  warn "Homebrew not found on PATH; skipping shell setup."
  exit 0
fi

PREFIX="$("$BREW" --prefix)"
ZDOT="${ZDOTDIR:-$HOME}"
ZPROFILE="$ZDOT/.zprofile"
ZSHRC="$ZDOT/.zshrc"
OHMY="$ZDOT/.oh-my-zsh"
ZSH_PATH="$PREFIX/bin/zsh"

# Ensure dotfiles exist
touch "$ZPROFILE" "$ZSHRC"

# Make Homebrew zsh your login shell (best-effort)
if [[ -x "$ZSH_PATH" ]]; then
  if ! grep -qs "^$ZSH_PATH$" /etc/shells 2>/dev/null; then
    echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null || true
  fi
  if [[ "${SHELL:-}" != "$ZSH_PATH" ]]; then
    chsh -s "$ZSH_PATH" "$USER" || true
  fi
fi

# Install Oh My Zsh if missing (non-interactive)
if [[ ! -d "$OHMY" ]]; then
  log "Installing Oh My Zsh (non-interactive)..."
  RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# Theme: powerlevel10k
if ! grep -q '^ZSH_THEME="powerlevel10k/powerlevel10k"' "$ZSHRC"; then
  echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC"
fi

# History configuration (idempotent)
append_history_setting() {
  local setting="$1"
  grep -q "^$setting" "$ZSHRC" || echo "$setting" >> "$ZSHRC"
}

# Configure history settings if not already present
append_history_setting 'export HISTSIZE=10000'
append_history_setting 'export SAVEHIST=10000'
append_history_setting 'export HISTFILE="$HOME/.zsh_history"'
append_history_setting 'setopt HIST_SAVE_NO_DUPS'
append_history_setting 'setopt HIST_IGNORE_DUPS'
append_history_setting 'setopt HIST_IGNORE_ALL_DUPS'
append_history_setting 'setopt HIST_FIND_NO_DUPS'
append_history_setting 'setopt HIST_IGNORE_SPACE'
append_history_setting 'setopt HIST_VERIFY'
append_history_setting 'setopt SHARE_HISTORY'
append_history_setting 'setopt APPEND_HISTORY'
append_history_setting 'setopt INC_APPEND_HISTORY'
append_history_setting 'setopt EXTENDED_HISTORY'

log "Ensured zsh history configuration in $ZSHRC"

# Aliases to replace built-ins (add only if not present)
append_alias() {
  local key="$1" line="$2"
  grep -q "^alias $key=" "$ZSHRC" || echo "$line" >> "$ZSHRC"
}
# append_alias fsf "alias fsf='fzf'"
# append_alias cat "alias cat='bat --paging=never'"
# append_alias grep "alias grep='rg'"
# append_alias find "alias find='fd'"

# Ensure managed block for brew plugins + zoxide exists
if ! grep -q ">>> brew-managed zsh plugins >>>" "$ZSHRC"; then
  cat >> "$ZSHRC" <<'EOF'

# >>> brew-managed zsh plugins >>>
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null)"
  if [ -n "$BREW_PREFIX" ]; then
    # Put Homebrew completions first
    fpath=("$BREW_PREFIX/share/zsh-completions" $fpath)

    # Initialize completion safely: fix insecure dirs, then compinit (-i ignores residual warnings)
    autoload -Uz compaudit compinit
    compaudit | while read -r d; do
      [ -e "$d" ] && chmod -R go-w "$d" 2>/dev/null || sudo chmod -R go-w "$d" 2>/dev/null || true
    done
    compinit -i

    # fzf keybindings/completions
    [ -r "$BREW_PREFIX/opt/fzf/shell/key-bindings.zsh" ] && source "$BREW_PREFIX/opt/fzf/shell/key-bindings.zsh"
    [ -r "$BREW_PREFIX/opt/fzf/shell/completion.zsh"    ] && source "$BREW_PREFIX/opt/fzf/shell/completion.zsh"

    # Plugins
    [ -r "$BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ] && source "$BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
    [ -r "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && source "$BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

    # zoxide init (smart cd)
    if command -v zoxide >/dev/null 2>&1; then
      # Default: keep 'cd' and provide `z`/`zi`
      eval "$(zoxide init zsh)"
      # --- Prefer zoxide to replace 'cd'? Uncomment the next line ---
      # eval "$(zoxide init zsh --cmd cd)"
      # --- Prefer an alias `cdi` for interactive 'zi'? Uncomment: ---
      # alias cdi='zi'
    fi
  fi
fi
# <<< brew-managed zsh plugins <<<
EOF
fi

# >>> macos-setup computer-specific aliases >>>
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ALIAS_TARGET="$HOME/.aliases.zsh"

source "$SCRIPT_DIR/config_common.sh"

# aliases.zsh is an AGGREGATE file: every tier that has one contributes,
# concatenated in default -> profiles (list order) -> host order. zsh's
# "last definition wins" means a later tier (a higher-priority profile,
# or the host) redefining an alias naturally overrides an earlier tier,
# consistent with the precedence stack. Because we concatenate multiple
# sources, ~/.aliases.zsh is a GENERATED FILE, not a symlink.
ALIAS_SOURCES=()
while IFS= read -r _af; do
  ALIAS_SOURCES+=("$_af")
done < <(resolve_aggregate "$REPO_ROOT" "aliases.zsh")

if [[ ${#ALIAS_SOURCES[@]} -eq 0 ]]; then
  warn "No aliases file found in default, profiles, or computer-specific, skipping aliases setup"
else
  for _af in "${ALIAS_SOURCES[@]}"; do
    log "Aggregating aliases: $_af"
  done

  # Back up an existing real file or replace a legacy symlink.
  if [[ -L "$ALIAS_TARGET" ]]; then
    rm "$ALIAS_TARGET"
  elif [[ -f "$ALIAS_TARGET" ]]; then
    mv "$ALIAS_TARGET" "$ALIAS_TARGET.backup"
  fi

  # Generate the concatenated aliases file.
  {
    echo "# Generated by scripts/shell_setup.sh — do not edit."
    echo "# Aggregated from (lowest to highest priority):"
    for _af in "${ALIAS_SOURCES[@]}"; do
      echo "#   ${_af#"$REPO_ROOT"/}"
    done
    for _af in "${ALIAS_SOURCES[@]}"; do
      echo ""
      echo "# >>> ${_af#"$REPO_ROOT"/} >>>"
      cat "$_af"
      echo "# <<< ${_af#"$REPO_ROOT"/} <<<"
    done
  } > "$ALIAS_TARGET"

  # Ensure .zshrc sources the aliases
  if [[ -f "$ZSHRC" ]]; then
    grep -qF 'source ~/.aliases.zsh' "$ZSHRC" || echo 'source ~/.aliases.zsh' >> "$ZSHRC"
  else
    echo 'source ~/.aliases.zsh' > "$ZSHRC"
  fi
  log "Aliases wired: $ALIAS_TARGET (aggregated ${#ALIAS_SOURCES[@]} source(s))"
fi
# <<< macos-setup computer-specific aliases <<<

# >>> macos-setup shared zsh helpers >>>
# Symlink <repo>/shared/zsh to ~/.zsh-shared and ensure ~/.zshrc sources every
# snippet in it. This directory is NOT three-tier resolved; it is shared
# library code that defines how macos-setup itself works.
SHARED_ZSH_DIR="$REPO_ROOT/shared/zsh"
SHARED_ZSH_SYMLINK="$HOME/.zsh-shared"

if [[ -d "$SHARED_ZSH_DIR" ]]; then
  # Replace an existing symlink pointing elsewhere, or back up a real dir/file
  if [[ -L "$SHARED_ZSH_SYMLINK" ]]; then
    if [[ "$(readlink "$SHARED_ZSH_SYMLINK")" != "$SHARED_ZSH_DIR" ]]; then
      rm "$SHARED_ZSH_SYMLINK"
    fi
  elif [[ -e "$SHARED_ZSH_SYMLINK" ]]; then
    mv "$SHARED_ZSH_SYMLINK" "$SHARED_ZSH_SYMLINK.backup"
  fi

  # Create the symlink if it doesn't already exist
  if [[ ! -L "$SHARED_ZSH_SYMLINK" ]]; then
    ln -s "$SHARED_ZSH_DIR" "$SHARED_ZSH_SYMLINK"
  fi

  # Ensure .zshrc sources every snippet in ~/.zsh-shared (idempotent).
  # The (N) glob qualifier enables nullglob for this pattern only, so the
  # loop silently does nothing if ~/.zsh-shared is missing or has no *.zsh
  # files (default zsh NOMATCH would otherwise abort shell startup).
  SHARED_SOURCE_LINE='for f in ~/.zsh-shared/*.zsh(N); do source "$f"; done'
  # Older installs may have the pre-nullglob form; leave user ~/.zshrc
  # alone if either form is already present (don't rewrite user files).
  SHARED_SOURCE_LINE_OLD='for f in ~/.zsh-shared/*.zsh; do source "$f"; done'
  if [[ -f "$ZSHRC" ]]; then
    if ! grep -qF "$SHARED_SOURCE_LINE" "$ZSHRC" \
      && ! grep -qF "$SHARED_SOURCE_LINE_OLD" "$ZSHRC"; then
      echo "$SHARED_SOURCE_LINE" >> "$ZSHRC"
    fi
  else
    echo "$SHARED_SOURCE_LINE" > "$ZSHRC"
  fi
  log "Shared zsh wired: $SHARED_ZSH_SYMLINK -> $SHARED_ZSH_DIR"
else
  warn "Shared zsh dir not found at $SHARED_ZSH_DIR, skipping shared zsh setup"
fi
# <<< macos-setup shared zsh helpers <<<

log "Shell setup complete. Launch a new terminal or run: exec zsh -l"

# >>> macos-setup zoxide init >>>
ZSHRC="$HOME/.zshrc"

# Fix any previously-added wrong line with '$$(zoxide init zsh)'
if [ -f "$ZSHRC" ] && grep -qF 'eval "$$(zoxide init zsh)"' "$ZSHRC"; then
  tmp="$(mktemp)"
  # portable sed (macOS/BSD): don't use -i; write to tmp and move
  sed 's|eval "\$\$(zoxide init zsh)"|eval "$(zoxide init zsh)"|g' "$ZSHRC" > "$tmp" && mv "$tmp" "$ZSHRC"
  echo "[shell_setup] Corrected bad zoxide init line in $ZSHRC"
fi

if command -v zoxide >/dev/null 2>&1; then
  if ! grep -qF 'zoxide init zsh' "$ZSHRC" 2>/dev/null; then
    echo 'eval "$(zoxide init zsh)"' >> "$ZSHRC"
    echo "[shell_setup] Appended zoxide init to $ZSHRC"
  fi
else
  echo "[shell_setup] WARNING: zoxide not installed yet; aliases cdz/cdi will not work until it is." >&2
fi
# <<< macos-setup zoxide init <<<

# >>> macos-setup asdf/direnv init >>>
# Idempotent asdf and direnv initialization (appends to ~/.zshrc only if missing)
_ms_ensure_line() {
  local line="$1" file="$2"
  [ -f "$file" ] || touch "$file"
  if ! grep -Fqx "$line" "$file" 2>/dev/null; then
    echo "$line" >> "$file"
    echo "[SHELL-SETUP] appended to $file: $line"
  fi
}

# Resolve Homebrew prefix
BREW_PREFIX="$(command -v brew >/dev/null 2>&1 && brew --prefix || echo /opt/homebrew)"
[ -n "$BREW_PREFIX" ] || BREW_PREFIX="/opt/homebrew"

# 1) Ensure asdf init line.
#    asdf 0.16+ is a single Go binary; there is no longer a libexec/asdf.sh
#    to source. The new init pattern (per upstream docs) is to put the
#    shims dir on PATH directly. Older runs of this script wrote a
#    `. /opt/homebrew/opt/asdf/libexec/asdf.sh` line into ~/.zshrc that now
#    fails on every shell startup, so first remove any such legacy line
#    (idempotent: a no-op once it's already gone), then ensure the new
#    PATH form is present exactly once.
#
#    The `^\. ` anchor (literal `. ` at start of line) is deliberate and
#    only matches the active form this script ever wrote. It intentionally
#    preserves indented or commented variants ("    . .../asdf.sh",
#    "# . .../asdf.sh") in case the user has hand-edited their ~/.zshrc to
#    keep the line around for reference -- those variants are inert and
#    safe to leave alone. Do not loosen the anchor.
ZSHRC_PATH="$HOME/.zshrc"
if [ -f "$ZSHRC_PATH" ] \
   && grep -Eq '^\. .*/opt/asdf/libexec/asdf\.sh[[:space:]]*$' "$ZSHRC_PATH"; then
  # Portable in-place edit via `sed -i.bak`, which writes the .bak backup
  # natively (consistent with the rest of this script's ~/.zshrc mutations).
  # Using `sed -i.bak` instead of a `grep -Ev` pipeline avoids a subtle
  # `set -euo pipefail` trap: `grep -Ev` exits 1 when its output is empty
  # (i.e. every input line matched the strip pattern), which would abort
  # the script before the subsequent _ms_ensure_line call -- leaving the
  # broken legacy line in place. `sed -d` has no such failure mode.
  sed -i.bak -E '/^\. .*\/opt\/asdf\/libexec\/asdf\.sh[[:space:]]*$/d' "$ZSHRC_PATH"
  echo "[SHELL-SETUP] Removed dead asdf init line (libexec/asdf.sh) from $ZSHRC_PATH (backup at $ZSHRC_PATH.bak)"
fi
_ms_ensure_line 'export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"' "$ZSHRC_PATH"

# 2) Ensure direnv hook
if command -v direnv >/dev/null 2>&1; then
  _ms_ensure_line 'eval "$(direnv hook zsh)"' "$HOME/.zshrc"
else
  echo "[SHELL-SETUP] NOTE: direnv not yet installed; hook will be added after install."
fi

# 3) Ensure asdf plugins (idempotent). Override with: ASDF_PLUGINS="python nodejs"
ASDF_BIN="$(command -v asdf || true)"
[ -z "$ASDF_BIN" ] && [ -x "$BREW_PREFIX/bin/asdf" ] && ASDF_BIN="$BREW_PREFIX/bin/asdf"
ASDF_PLUGINS_DEFAULT="python nodejs"
ASDF_PLUGINS="${ASDF_PLUGINS:-$ASDF_PLUGINS_DEFAULT}"
if [ -n "$ASDF_BIN" ]; then
  # list existing plugins once to avoid multiple spawns
  EXISTING="$("$ASDF_BIN" plugin list 2>/dev/null || true)"
  for plug in $ASDF_PLUGINS; do
    echo "$EXISTING" | grep -qx "$plug" && continue
    case "$plug" in
      python) "$ASDF_BIN" plugin add python https://github.com/asdf-community/asdf-python.git || true ;;
      nodejs) "$ASDF_BIN" plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git      || true ;;
      *)      "$ASDF_BIN" plugin add "$plug"                                              || true ;;
    esac
    echo "[SHELL-SETUP] asdf plugin ensured: $plug"
  done
else
  echo "[SHELL-SETUP] NOTE: asdf CLI not on PATH yet; skipping plugin ensure."
fi
# <<< macos-setup asdf/direnv init <<<

# >>> macos-setup PATH and claude symlink >>>
# Ensure $HOME/.local/bin exists and is in PATH
LOCAL_BIN="$HOME/.local/bin"
ZSHRC="$HOME/.zshrc"

# Create .local/bin directory if it doesn't exist
if [ ! -d "$LOCAL_BIN" ]; then
  mkdir -p "$LOCAL_BIN"
  echo "[SHELL-SETUP] Created directory: $LOCAL_BIN"
fi

# Add PATH export to .zshrc if not already present
PATH_EXPORT='export PATH="$HOME/.local/bin:$PATH"'
if [ -f "$ZSHRC" ] && ! grep -qF "$PATH_EXPORT" "$ZSHRC"; then
  echo "$PATH_EXPORT" >> "$ZSHRC"
  echo "[SHELL-SETUP] Added PATH export to $ZSHRC"
fi

# Create claude symlink if claude is installed via Homebrew
CLAUDE_HOMEBREW="/opt/homebrew/bin/claude"
CLAUDE_SYMLINK="$LOCAL_BIN/claude"
if [ -x "$CLAUDE_HOMEBREW" ]; then
  if [ ! -L "$CLAUDE_SYMLINK" ] || [ "$(readlink "$CLAUDE_SYMLINK")" != "$CLAUDE_HOMEBREW" ]; then
    ln -sf "$CLAUDE_HOMEBREW" "$CLAUDE_SYMLINK"
    echo "[SHELL-SETUP] Created claude symlink: $CLAUDE_SYMLINK -> $CLAUDE_HOMEBREW"
  fi
else
  echo "[SHELL-SETUP] NOTE: claude not found at $CLAUDE_HOMEBREW; install via Install/17-Install.ai first"
fi
# <<< macos-setup PATH and claude symlink <<<
