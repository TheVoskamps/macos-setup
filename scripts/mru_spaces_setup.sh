#!/bin/bash

# Turn off "Automatically rearrange Spaces based on most recent use"
# (com.apple.dock mru-spaces) when a resolved monitors.json asks for
# fullscreen Spaces. While it is on, macOS reorders Spaces by recent use
# and undoes the `apps` order the Hammerspoon sorter sets. It never turns
# the setting on.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"

MONITORS_JSON="$(resolve_file "$REPO_ROOT" ".hammerspoon/monitors.json")"

if ! monitors_want_fullscreen "$MONITORS_JSON"; then
    echo "No fullscreen monitor configured; leaving mru-spaces unchanged"
    exit 0
fi

if [[ "$(defaults read com.apple.dock mru-spaces 2>/dev/null)" == "0" ]]; then
    echo "mru-spaces already off"
    exit 0
fi

echo "Turning off mru-spaces so fullscreen Spaces keep their order..."
defaults write com.apple.dock mru-spaces -bool false
killall Dock
echo "mru-spaces turned off; Dock restarted"
