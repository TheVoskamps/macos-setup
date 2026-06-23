#!/bin/bash

# Configure macOS "Switch to Desktop N" keyboard shortcuts
# Sets Ctrl+1 through Ctrl+9 for switching between Spaces
#
# Symbolic hotkey IDs 118-126 map to "Switch to Desktop 1-9"
# Modifier: Ctrl (control key) = 262144
#
# This is required for the Hammerspoon title-bar-drag workaround
# which uses Ctrl+N to switch Spaces during window drag operations.

set -e

DOMAIN="com.apple.symbolichotkeys"

# Modifier flags for Ctrl key
CTRL_MODIFIER=262144

# Symbolic hotkey IDs for "Switch to Desktop 1-9"
# ID 118 = Desktop 1, 119 = Desktop 2, ..., 126 = Desktop 9
BASE_HOTKEY_ID=118

# Keycodes for number keys 1-9
# macOS keycodes: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25
KEYCODES=(18 19 20 21 23 22 26 28 25)

configure_shortcut() {
    local desktop_num=$1
    local hotkey_id=$((BASE_HOTKEY_ID + desktop_num - 1))
    local keycode=${KEYCODES[$((desktop_num - 1))]}

    # Check if already configured correctly
    local current
    current=$(defaults read "$DOMAIN" AppleSymbolicHotKeys 2>/dev/null | \
        grep -A 10 "\"$hotkey_id\"" 2>/dev/null || echo "")

    if echo "$current" | grep -q "enabled = 1" && \
       echo "$current" | grep -q "$CTRL_MODIFIER" && \
       echo "$current" | grep -q "$keycode"; then
        echo "  Desktop $desktop_num (Ctrl+$desktop_num): already configured"
        return 0
    fi

    # Write the shortcut configuration
    # Format: {enabled = 1; value = {parameters = (keycode, keycode, modifiers); type = standard;}}
    defaults write "$DOMAIN" AppleSymbolicHotKeys -dict-add "$hotkey_id" \
        "<dict>
            <key>enabled</key>
            <true/>
            <key>value</key>
            <dict>
                <key>parameters</key>
                <array>
                    <integer>$((desktop_num + 48))</integer>
                    <integer>$keycode</integer>
                    <integer>$CTRL_MODIFIER</integer>
                </array>
                <key>type</key>
                <string>standard</string>
            </dict>
        </dict>"

    echo "  Desktop $desktop_num (Ctrl+$desktop_num): configured (hotkey ID $hotkey_id)"
}

echo "Configuring Switch to Desktop shortcuts (Ctrl+1 through Ctrl+9)..."

for i in $(seq 1 9); do
    configure_shortcut "$i"
done

# Apply changes without requiring logout
echo ""
echo "Applying settings..."
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null && \
    echo "Settings applied successfully" || \
    echo "Note: activateSettings not available; changes take effect after logout"

echo "Switch to Desktop shortcuts setup complete"
