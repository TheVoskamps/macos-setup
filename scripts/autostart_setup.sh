#!/bin/bash

# Write the com.macos-setup.autostart LaunchAgent, which runs
# scripts/autostart_launch.sh at every login to start the apps the
# [autostart] section of config.toml names.
#
# The plist is built the way the Makefile `schedule-*` targets build
# theirs, through launchagent_runner, and is written whether or not the
# resolved app list is empty: the list is read at login, not here.
#
# The plist is rewritten only when its content differs, and launchctl is
# never called: launchd loads the agent at the next login, so an install
# run never launches apps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/autostart_common.sh"

PLIST_BUDDY=/usr/libexec/PlistBuddy
PLIST="$(autostart_plist_path)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
NEW="$STAGING/$(basename "$PLIST")"

"$PLIST_BUDDY" -c "Clear dict" "$NEW" >/dev/null
"$PLIST_BUDDY" -c "Add :Label string com.macos-setup.autostart" "$NEW"
"$PLIST_BUDDY" -c "Add :ProgramArguments array" "$NEW"
"$PLIST_BUDDY" -c "Add :ProgramArguments:0 string $HOME/.zsh-shared/launchagent_runner" "$NEW"
"$PLIST_BUDDY" -c "Add :ProgramArguments:1 string autostart" "$NEW"
"$PLIST_BUDDY" -c "Add :ProgramArguments:2 string --" "$NEW"
"$PLIST_BUDDY" -c "Add :ProgramArguments:3 string scripts/autostart_launch.sh" "$NEW"
"$PLIST_BUDDY" -c "Add :RunAtLoad bool true" "$NEW"
"$PLIST_BUDDY" -c "Add :EnvironmentVariables dict" "$NEW"
"$PLIST_BUDDY" -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$NEW"

if [[ -f "$PLIST" ]] && cmp -s "$NEW" "$PLIST"; then
    echo "Autostart LaunchAgent up to date: $PLIST"
    exit 0
fi

mkdir -p "$(dirname "$PLIST")"
cp "$NEW" "$PLIST"
echo "Autostart LaunchAgent written: $PLIST (loads at next login)"
