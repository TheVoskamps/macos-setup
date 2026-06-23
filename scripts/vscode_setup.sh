#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
VSC_USER_DIR="$HOME/Library/Application Support/Code/User"

source "$SCRIPT_DIR/config_common.sh"

echo "Setting up Visual Studio Code configuration..."

HOSTNAME_LOWER=$(get_hostname)
PROFILES=$(get_profiles "$REPO_ROOT" | paste -sd ' ' -)
echo "Detected hostname: $HOSTNAME_LOWER"
if [[ -n "$PROFILES" ]]; then
    echo "Using profiles (low to high priority): $PROFILES"
fi

# Create VSC User directory if it doesn't exist
mkdir -p "$VSC_USER_DIR"

# Resolve settings.json through three-tier fallback
SOURCE_FILE=$(resolve_file "$REPO_ROOT" ".vscode/settings.json")
if [[ -z "$SOURCE_FILE" ]]; then
    echo "Error: No VS Code settings found in computer-specific, profile, or default"
    exit 1
fi
echo "Using config: $SOURCE_FILE"

# Remove existing symlink or file if it exists
if [[ -L "$VSC_USER_DIR/settings.json" ]]; then
    echo "Removing existing symlink..."
    rm "$VSC_USER_DIR/settings.json"
elif [[ -f "$VSC_USER_DIR/settings.json" ]]; then
    echo "Backing up existing settings.json to settings.json.backup..."
    mv "$VSC_USER_DIR/settings.json" "$VSC_USER_DIR/settings.json.backup"
fi

# Create the symlink
echo "Creating symlink: $VSC_USER_DIR/settings.json -> $SOURCE_FILE"
ln -s "$SOURCE_FILE" "$VSC_USER_DIR/settings.json"

# Add VSCode-specific environment variables to .zshrc (idempotent)
ZSHRC="$HOME/.zshrc"
if [[ -f "$ZSHRC" ]]; then
    echo "Adding VSCode terminal settings to .zshrc..."

    # Add TERM setting if not present
    if ! grep -q "^export TERM=xterm-256color" "$ZSHRC"; then
        echo "" >> "$ZSHRC"
        echo "# Force proper alternate screen handling" >> "$ZSHRC"
        echo "export TERM=xterm-256color" >> "$ZSHRC"
        echo "Added TERM=xterm-256color to .zshrc"
    else
        echo "TERM=xterm-256color already in .zshrc"
    fi

    # Add VSCODE_TERMINAL setting if not present
    if ! grep -q "^export VSCODE_TERMINAL=1" "$ZSHRC"; then
        echo "# Disable VSCode terminal's problematic scrollback interaction" >> "$ZSHRC"
        echo "export VSCODE_TERMINAL=1" >> "$ZSHRC"
        echo "Added VSCODE_TERMINAL=1 to .zshrc"
    else
        echo "VSCODE_TERMINAL=1 already in .zshrc"
    fi
else
    echo "Warning: .zshrc not found at $ZSHRC"
fi

echo "Visual Studio Code configuration setup complete!"
echo "Config file: $(readlink "$VSC_USER_DIR/settings.json")"
