#!/bin/bash

# Shared helpers for the autostart LaunchAgent and the apps it starts.
#
# Sourced (never executed) by scripts/autostart_setup.sh,
# scripts/autostart_launch.sh, and scripts/verify.sh. The resolved app
# list itself is a config read, and comes from resolve_autostart_apps in
# scripts/config_common.sh.

# Print the path of the first `<name>.app` found in /Applications,
# /System/Applications, then ~/Applications, or nothing when none has
# it. Args: app name
#
# The name is compared against each directory's entries rather than
# tested with `-d "$dir/$name.app"`: the default macOS volume is
# case-insensitive, so a path test would accept a name cased differently
# from the bundle.
autostart_app_path() {
    local name="$1" dir entry
    for dir in /Applications /System/Applications "$HOME/Applications"; do
        for entry in "$dir"/*.app; do
            if [[ "${entry##*/}" == "$name.app" && -d "$entry" ]]; then
                echo "$entry"
                return 0
            fi
        done
    done
}

# Print the path of the LaunchAgent plist scripts/autostart_setup.sh
# writes and scripts/verify.sh checks for.
autostart_plist_path() {
    echo "$HOME/Library/LaunchAgents/com.macos-setup.autostart.plist"
}
