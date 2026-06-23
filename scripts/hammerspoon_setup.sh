#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

source "$SCRIPT_DIR/config_common.sh"

echo "Setting up Hammerspoon configuration..."

HOSTNAME_LOWER=$(get_hostname)
PROFILES=$(get_profiles "$REPO_ROOT" | paste -sd ' ' -)
echo "Detected hostname: $HOSTNAME_LOWER"
if [[ -n "$PROFILES" ]]; then
    echo "Using profiles (low to high priority): $PROFILES"
fi

# Create .hammerspoon directory if it doesn't exist
mkdir -p "$HAMMERSPOON_DIR"

# Resolve init.lua through three-tier fallback
SOURCE_FILE=$(resolve_file "$REPO_ROOT" ".hammerspoon/init.lua")
if [[ -z "$SOURCE_FILE" ]]; then
    echo "Error: No Hammerspoon init.lua found in computer-specific, profile, or default"
    exit 1
fi
echo "Using config: $SOURCE_FILE"

# Remove existing symlink or file if it exists
if [[ -L "$HAMMERSPOON_DIR/init.lua" ]]; then
    echo "Removing existing symlink..."
    rm "$HAMMERSPOON_DIR/init.lua"
elif [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    echo "Backing up existing init.lua to init.lua.backup..."
    mv "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
fi

# Create the symlink
echo "Creating symlink: $HAMMERSPOON_DIR/init.lua -> $SOURCE_FILE"
ln -s "$SOURCE_FILE" "$HAMMERSPOON_DIR/init.lua"

echo "Hammerspoon init.lua setup complete!"
echo "Config file: $(readlink "$HAMMERSPOON_DIR/init.lua")"

# Symlink JSON config files
echo ""
echo "Setting up JSON config files..."
for config_file in monitors.json workspaces.json; do
    SOURCE_CONFIG=$(resolve_file "$REPO_ROOT" ".hammerspoon/$config_file")
    if [[ -z "$SOURCE_CONFIG" ]]; then
        echo "No $config_file found, skipping"
        continue
    fi
    echo "Using config: $SOURCE_CONFIG"

    TARGET_CONFIG="$HAMMERSPOON_DIR/$config_file"

    if [[ -L "$TARGET_CONFIG" ]]; then
        echo "Removing existing symlink for $config_file..."
        rm "$TARGET_CONFIG"
    elif [[ -f "$TARGET_CONFIG" ]]; then
        echo "Backing up existing $config_file to $config_file.backup..."
        mv "$TARGET_CONFIG" "$TARGET_CONFIG.backup"
    fi

    echo "Creating symlink: $TARGET_CONFIG -> $SOURCE_CONFIG"
    ln -s "$SOURCE_CONFIG" "$TARGET_CONFIG"
done

# Symlink modules/ directory through three-tier fallback
echo ""
echo "Setting up Hammerspoon modules..."
SOURCE_MODULES=$(resolve_dir "$REPO_ROOT" ".hammerspoon/modules")
if [[ -n "$SOURCE_MODULES" ]]; then
    TARGET_MODULES="$HAMMERSPOON_DIR/modules"

    if [[ -L "$TARGET_MODULES" ]]; then
        echo "Removing existing modules symlink..."
        rm "$TARGET_MODULES"
    elif [[ -d "$TARGET_MODULES" ]]; then
        echo "Backing up existing modules/ to modules.backup..."
        mv "$TARGET_MODULES" "$HAMMERSPOON_DIR/modules.backup"
    fi

    echo "Creating symlink: $TARGET_MODULES -> $SOURCE_MODULES"
    ln -s "$SOURCE_MODULES" "$TARGET_MODULES"
else
    echo "No modules/ directory found, skipping"
fi

# Configure Ctrl+1-9 desktop switching shortcuts
SPACES_SCRIPT="$SCRIPT_DIR/spaces_shortcuts_setup.sh"
if [[ -x "$SPACES_SCRIPT" ]]; then
    echo ""
    echo "Configuring desktop switching shortcuts..."
    "$SPACES_SCRIPT"
else
    echo ""
    echo "spaces_shortcuts_setup.sh not found or not executable, skipping"
fi

echo ""
echo "Hammerspoon configuration setup complete!"

# Reload Hammerspoon if it's running
if pgrep -q Hammerspoon; then
    hs -c "hs.reload()" 2>/dev/null && echo "Hammerspoon config reloaded" || echo "Note: Could not reload Hammerspoon (is the IPC module enabled?)"
fi
